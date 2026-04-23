defmodule ContentForge.OpenClawTools.DraftStatus do
  @moduledoc """
  OpenClaw tool: reports the current status of a draft so the agent
  can answer questions like "is the Johnson kitchen post ready?".

  Params (one of the two id-paths is required):

    * `"draft_id"` - exact UUID. When paired with `"product"` the
      resolved product must own the draft or the tool returns
      `:not_found`.
    * `"hint"` - free-text fragment matched case-insensitively
      against `content` or `angle` within the resolved product
      scope. A single match wins; multiple matches surface as
      `{:ambiguous_draft, %{candidates: [...]}}` with up to three
      short candidate snippets so the agent can ask the user which
      draft they mean.

  Params (optional):

    * `"product"` - resolved via `ProductResolver` before the
      draft lookup. SMS callers can omit this once a phone is
      registered.

  Result map fields: `draft_id, product_id, product_name,
  content_type, platform, angle, status, generating_model,
  approved_at, approval_required, blocker, updated_at`.

  Errors: `:missing_product_context`, `:product_not_found`,
  `:ambiguous_product`, `:not_found`, `{:ambiguous_draft, %{...}}`.
  """

  import Ecto.Query, only: [from: 2]

  alias ContentForge.ContentGeneration
  alias ContentForge.ContentGeneration.Draft
  alias ContentForge.OpenClawTools.ProductResolver
  alias ContentForge.Repo

  @blog_platform "blog"
  @approved_terminal_statuses ~w(approved published)
  @snippet_length 200
  @max_candidates 3

  @spec call(map(), map()) :: {:ok, map()} | {:error, term()}
  def call(ctx, params) when is_map(params) do
    with {:ok, product} <- ProductResolver.resolve(ctx, params),
         {:ok, draft} <- locate_draft(product, params) do
      {:ok, build_result(draft, product)}
    end
  end

  # --- draft location -------------------------------------------------------

  defp locate_draft(product, params) do
    cond do
      binary?(params["draft_id"]) -> lookup_by_id(product, params["draft_id"])
      binary?(params["hint"]) -> lookup_by_hint(product, params["hint"])
      true -> {:error, :not_found}
    end
  end

  defp binary?(value), do: is_binary(value) and value != ""

  defp lookup_by_id(product, draft_id) do
    case safe_get_draft(draft_id) do
      %Draft{product_id: pid} = draft when pid == product.id -> {:ok, draft}
      _ -> {:error, :not_found}
    end
  end

  defp safe_get_draft(id) do
    ContentGeneration.get_draft(id)
  rescue
    Ecto.Query.CastError -> nil
  end

  defp lookup_by_hint(product, hint) do
    pattern = "%" <> escape_like(hint) <> "%"

    query =
      from(d in Draft,
        where: d.product_id == ^product.id,
        where: ilike(d.content, ^pattern) or ilike(d.angle, ^pattern),
        order_by: [desc: d.updated_at],
        limit: @max_candidates + 1
      )

    case Repo.all(query) do
      [] -> {:error, :not_found}
      [draft] -> {:ok, draft}
      multiple -> {:error, {:ambiguous_draft, %{candidates: candidates(multiple)}}}
    end
  end

  defp escape_like(str) do
    str
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  defp candidates(drafts) do
    drafts
    |> Enum.take(@max_candidates)
    |> Enum.map(fn draft ->
      %{id: draft.id, status: draft.status, snippet: snippet(draft.content)}
    end)
  end

  # --- result shape ---------------------------------------------------------

  defp build_result(%Draft{} = draft, product) do
    %{
      draft_id: draft.id,
      product_id: product.id,
      product_name: product.name,
      content_type: draft.content_type,
      platform: draft.platform,
      angle: draft.angle,
      status: draft.status,
      generating_model: draft.generating_model,
      approved_at: approved_at(draft),
      approval_required: approval_required?(draft),
      blocker: blocker(draft),
      updated_at: iso8601(draft.updated_at)
    }
  end

  defp approval_required?(%Draft{platform: @blog_platform, status: status}) do
    status not in @approved_terminal_statuses and status not in ~w(rejected archived)
  end

  defp approval_required?(_), do: false

  defp approved_at(%Draft{status: status, updated_at: updated_at})
       when status in @approved_terminal_statuses,
       do: iso8601(updated_at)

  defp approved_at(_), do: nil

  defp blocker(%Draft{status: "blocked", error: error}) when is_binary(error), do: error
  defp blocker(_), do: nil

  defp snippet(nil), do: ""
  defp snippet(content), do: content |> to_string() |> String.slice(0, @snippet_length)

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp iso8601(%NaiveDateTime{} = ndt) do
    ndt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()
  end
end
