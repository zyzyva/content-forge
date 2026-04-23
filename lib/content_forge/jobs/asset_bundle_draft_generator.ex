defmodule ContentForge.Jobs.AssetBundleDraftGenerator do
  @moduledoc """
  Oban worker that asks Anthropic for N social-post variants per platform
  grounded in an `AssetBundle` (bundle name + context + per-asset filename,
  description, tags in position order), then persists each variant as a
  `Draft` tied back to the bundle with the bundle's first-position asset
  attached as the "featured" media and that asset's storage key copied
  onto `draft.image_url` for the existing Stage-3.5 publisher gate.

  `draft.image_url` stays authoritative for publishing in this slice;
  Phase 13.5 will swap the publisher to read from `draft_assets` directly.

  ## Args

      %{
        "bundle_id" => binary_id,
        "platforms" => ["twitter", "linkedin", ...],
        "variants_per_platform" => pos_integer()
      }

  ## Failure modes (mirroring `ContentBriefGenerator` taxonomy)

    * `{:error, :not_configured}` from Anthropic -log + `{:ok, :skipped}`,
      zero drafts created.
    * Malformed JSON in the response -log + `{:cancel, "malformed LLM output"}`.
    * Transient errors (`{:transient, ...}`) -`{:error, _}` so Oban retries.
    * Permanent HTTP errors (4xx, unexpected_status) -`{:cancel, ...}`.

  ## Bundle guards

    * A bundle with no assets cancels the job: we need at least a
      featured asset to populate `draft.image_url`.
  """
  use Oban.Worker, queue: :content_generation, max_attempts: 3
  require Logger

  alias ContentForge.ContentGeneration
  alias ContentForge.LLM.Anthropic
  alias ContentForge.ProductAssets
  alias ContentForge.ProductAssets.AssetBundle
  alias ContentForge.ProductAssets.BundleAsset

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{
          "bundle_id" => bundle_id,
          "platforms" => platforms,
          "variants_per_platform" => n
        }
      })
      when is_binary(bundle_id) and is_list(platforms) and is_integer(n) and n > 0 do
    bundle = ProductAssets.get_bundle!(bundle_id)

    bundle
    |> featured_asset()
    |> generate_with_featured(bundle, platforms, n)
  end

  defp featured_asset(%AssetBundle{bundle_assets: [%BundleAsset{asset: asset} | _]})
       when not is_nil(asset),
       do: {:ok, asset}

  defp featured_asset(%AssetBundle{}), do: :empty

  defp generate_with_featured(:empty, %AssetBundle{id: id}, _platforms, _n) do
    Logger.warning("AssetBundleDraftGenerator: bundle #{id} has no assets; cancelling")
    {:cancel, "bundle has no assets"}
  end

  defp generate_with_featured({:ok, asset}, bundle, platforms, n) do
    prompt = build_user_prompt(bundle, platforms, n)
    system = system_prompt()

    prompt
    |> Anthropic.complete(system: system)
    |> handle_completion(bundle, asset, platforms, n)
  end

  # --- LLM result handling --------------------------------------------------

  defp handle_completion({:ok, %{text: text, model: model}}, bundle, asset, platforms, n) do
    case extract_json(text) do
      {:ok, payload} -> persist_variants(payload, bundle, asset, platforms, n, model)
      :error -> log_malformed_and_cancel(bundle.id, text)
    end
  end

  defp handle_completion({:error, :not_configured}, %AssetBundle{id: id}, _asset, _platforms, _n) do
    Logger.warning("AssetBundleDraftGenerator: LLM unavailable; skipping bundle #{id}")
    {:ok, :skipped}
  end

  defp handle_completion(
         {:error, {:transient, _, _} = reason},
         %AssetBundle{id: id},
         _asset,
         _platforms,
         _n
       ) do
    Logger.warning(
      "AssetBundleDraftGenerator: transient LLM error for bundle #{id}; Oban will retry (#{inspect(reason)})"
    )

    {:error, reason}
  end

  defp handle_completion(
         {:error, {:http_error, status, body}},
         %AssetBundle{id: id},
         _asset,
         _platforms,
         _n
       ) do
    Logger.error(
      "AssetBundleDraftGenerator: permanent LLM error #{status} for bundle #{id}: #{inspect(body)}"
    )

    {:cancel, "LLM rejected generation request (HTTP #{status})"}
  end

  defp handle_completion(
         {:error, {:unexpected_status, status, _body}},
         %AssetBundle{id: id},
         _asset,
         _platforms,
         _n
       ) do
    Logger.error(
      "AssetBundleDraftGenerator: LLM returned unexpected HTTP status #{status} for bundle #{id}"
    )

    {:cancel, "LLM returned unexpected HTTP status #{status}"}
  end

  defp handle_completion({:error, reason}, %AssetBundle{id: id}, _asset, _platforms, _n) do
    Logger.error(
      "AssetBundleDraftGenerator: unexpected LLM error for bundle #{id}: #{inspect(reason)}"
    )

    {:error, reason}
  end

  defp log_malformed_and_cancel(bundle_id, text) do
    Logger.error(
      "AssetBundleDraftGenerator: malformed LLM output for bundle #{bundle_id}: #{inspect(text)}"
    )

    {:cancel, "malformed LLM output"}
  end

  # --- draft persistence ----------------------------------------------------

  defp persist_variants(%{"platforms" => platforms_map}, bundle, asset, platforms, n, model)
       when is_map(platforms_map) do
    descriptor = "anthropic:#{model}"

    drafts =
      Enum.flat_map(platforms, fn platform ->
        variants = platforms_map[platform] || platforms_map[to_string(platform)] || []

        variants
        |> Enum.take(n)
        |> Enum.map(&create_variant(&1, platform, bundle, asset, descriptor))
      end)

    Logger.info(
      "AssetBundleDraftGenerator: bundle #{bundle.id} generated #{length(drafts)} drafts across #{length(platforms)} platform(s) via #{descriptor}"
    )

    {:ok, drafts}
  end

  defp persist_variants(_other, bundle, _asset, _platforms, _n, _model),
    do: log_malformed_and_cancel(bundle.id, "payload missing platforms map")

  defp create_variant(text, platform, bundle, asset, descriptor) when is_binary(text) do
    {:ok, draft} =
      ContentGeneration.create_draft(%{
        product_id: bundle.product_id,
        bundle_id: bundle.id,
        content: text,
        platform: platform,
        content_type: "post",
        generating_model: descriptor,
        image_url: asset.storage_key
      })

    {:ok, _} = ContentGeneration.attach_asset(draft, asset, role: "featured")
    draft
  end

  # --- JSON extraction ------------------------------------------------------

  defp extract_json(text) when is_binary(text) do
    trimmed = String.trim(text)

    case JSON.decode(trimmed) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      _ -> try_fenced(trimmed)
    end
  end

  defp extract_json(_), do: :error

  defp try_fenced(text) do
    case Regex.run(~r/```(?:json)?\s*(\{.*?\})\s*```/s, text) do
      [_, inner] ->
        case JSON.decode(inner) do
          {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  # --- prompts --------------------------------------------------------------

  defp system_prompt do
    """
    You are a senior social content writer. Given an asset bundle (a
    named collection of product media) and a list of target platforms,
    produce multiple short-post variants per platform that a human can
    edit and publish.

    Respond with a single JSON object and nothing else, in exactly this
    shape (extra keys allowed but ignored):

        {
          "platforms": {
            "<platform_name>": ["variant 1", "variant 2", ...]
          }
        }

    Each variant is a single post. Honor the requested number of
    variants per platform. Ground the content in the supplied bundle
    context and asset manifest. Never fabricate details that are not
    present in the input.
    """
  end

  defp build_user_prompt(%AssetBundle{} = bundle, platforms, n) do
    context = bundle.context || "(no additional context)"

    asset_manifest =
      bundle.bundle_assets
      |> Enum.with_index(1)
      |> Enum.map_join("\n", &render_asset/1)

    """
    Bundle: #{bundle.name}
    Context: #{context}

    Assets (in display order):
    #{asset_manifest}

    Platforms: #{Enum.join(platforms, ", ")}
    Variants per platform: #{n}

    Generate #{n} variant(s) per platform grounded in the bundle.
    """
  end

  defp render_asset({%BundleAsset{asset: asset}, idx}) do
    tags = format_tags(asset.tags)
    description = asset.description || "(no description)"

    "#{idx}. #{asset.filename} - media_type=#{asset.media_type} tags=#{tags} description=#{description}"
  end

  defp format_tags(nil), do: "[]"
  defp format_tags([]), do: "[]"
  defp format_tags(tags) when is_list(tags), do: "[" <> Enum.join(tags, ", ") <> "]"
end
