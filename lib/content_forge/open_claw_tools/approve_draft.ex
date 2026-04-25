defmodule ContentForge.OpenClawTools.ApproveDraft do
  @moduledoc """
  OpenClaw tool: approves a draft through the Phase 12.4 publish
  gate (blog drafts) or via the override path when the gate
  would block and the caller supplies a justification. First
  real consumer of the two-turn confirmation envelope (16.4a).

  Authorization: requires `:owner` on the resolved product.

  Params (required):

    * `"draft_id"` - exact UUID of a draft owned by the resolved
      product. Cross-product or unknown ids collapse to
      `:not_found` uniformly.

  Params (optional):

    * `"override_reason"` - free-text justification (min 20 chars
      after trimming). Required when the publish gate would
      otherwise block; absent + gate-blocks = `:publish_gate_blocks`
      on confirm.
    * `"product"` - resolved via `ProductResolver`. SMS callers
      can omit once a phone is registered.
    * `"confirm"` - echo phrase from the first-turn envelope.
      Present on the second call; absent on the first.

  Flow:

    1. Resolve product.
    2. Fetch draft scoped to product (`:not_found` on miss).
    3. Authorize `:owner`.
    4. No `"confirm"`: compute a preview + ask
       `Confirmation.request/4` and return
       `{:ok, :confirmation_required, envelope}`.
    5. With `"confirm"`: `Confirmation.confirm/4` to verify and
       mark consumed, then route to the 12.4 approval flow.
       Blog drafts with `override_reason` take the override
       path; without a reason and the gate blocks they surface
       `:publish_gate_blocks`.

  Returns `%{draft_id, status, approved_at, approved_via_override,
  override_reason}` on successful execution (second turn),
  `{:ok, :confirmation_required, envelope}` on the first turn,
  or a classified error.

  Errors: `:missing_product_context`, `:product_not_found`,
  `:ambiguous_product`, `:forbidden`, `:not_found`,
  `:publish_gate_blocks`, confirmation reasons
  (`:missing_session`, `:confirmation_not_found`,
  `:confirmation_mismatch`, `:confirmation_expired`),
  plus `:override_reason_too_short` when the override path
  refuses a short reason.
  """

  alias ContentForge.ContentGeneration
  alias ContentForge.ContentGeneration.Draft
  alias ContentForge.OpenClawTools.Authorization
  alias ContentForge.OpenClawTools.Confirmation
  alias ContentForge.OpenClawTools.ProductResolver

  @tool_name "approve_draft"
  @snippet_length 200

  @spec call(map(), map()) ::
          {:ok, map()} | {:ok, :confirmation_required, map()} | {:error, term()}
  def call(ctx, params) when is_map(params) do
    with {:ok, product} <- ProductResolver.resolve(ctx, params),
         {:ok, draft} <- fetch_draft(product, params),
         :ok <- Authorization.require(Map.put(ctx, :product, product), :owner) do
      dispatch_turn(ctx, params, product, draft)
    end
  end

  # --- turn dispatch --------------------------------------------------------

  defp dispatch_turn(ctx, params, product, draft) do
    case binary_param(params, "confirm") do
      nil -> request_turn(ctx, params, product, draft)
      echo -> confirm_turn(ctx, params, draft, echo)
    end
  end

  defp request_turn(ctx, params, product, draft) do
    preview = build_preview(params, product, draft)

    Confirmation.request(@tool_name, ctx, params, preview)
    |> case do
      {:ok, envelope} -> {:ok, :confirmation_required, envelope}
      {:error, _} = err -> err
    end
  end

  defp confirm_turn(ctx, params, draft, echo) do
    case Confirmation.confirm(@tool_name, ctx, params, echo) do
      :ok -> execute_approval(params, draft)
      {:error, _} = err -> err
    end
  end

  # --- execution ------------------------------------------------------------

  defp execute_approval(params, %Draft{} = draft) do
    reason = binary_param(params, "override_reason")
    gate_status = publish_gate_status(draft)

    apply_approval(draft, gate_status, reason)
    |> case do
      {:ok, approved} -> {:ok, result_from_draft(approved)}
      {:error, reason_tuple} -> classify_approval_error(reason_tuple)
    end
  end

  defp apply_approval(draft, :passes, nil), do: ContentGeneration.approve_blog_draft(draft)

  defp apply_approval(draft, :passes, reason) when is_binary(reason),
    do: ContentGeneration.approve_blog_draft_with_override(draft, reason)

  defp apply_approval(_draft, :blocks, nil), do: {:error, :publish_gate_blocks}

  defp apply_approval(draft, :blocks, reason) when is_binary(reason),
    do: ContentGeneration.approve_blog_draft_with_override(draft, reason)

  # approve_blog_draft_with_override returns
  # `{:error, :override_reason_too_short, details}`; approve_blog_draft
  # returns `{:error, :seo_below_threshold, ...}` or
  # `{:error, :research_lost_data, ...}` for blog drafts. Normalize
  # everything the tool surface returns into a single `{:error, atom}`
  # reason tuple so the controller can serialize uniformly.
  defp classify_approval_error({kind, _details}) when is_atom(kind), do: {:error, kind}
  defp classify_approval_error({kind, _msg, _details}) when is_atom(kind), do: {:error, kind}
  defp classify_approval_error(other), do: {:error, other}

  # --- preview --------------------------------------------------------------

  defp build_preview(params, product, draft) do
    gate = publish_gate_status(draft)
    reason_present = is_binary(binary_param(params, "override_reason"))

    %{
      summary: summary(draft, product),
      draft_id: draft.id,
      platform: draft.platform,
      content_type: draft.content_type,
      angle: draft.angle,
      snippet: snippet(draft.content),
      publish_gate: gate,
      required_override: gate == :blocks,
      override_reason_present: reason_present
    }
  end

  defp summary(%Draft{} = draft, product) do
    angle = draft.angle || draft.content_type
    "Approve the #{angle} draft on #{draft.platform} for #{product.name}."
  end

  defp snippet(nil), do: ""
  defp snippet(content), do: content |> to_string() |> String.slice(0, @snippet_length)

  # Pure gate status: mirrors ContentGeneration.approve_blog_draft/2's
  # blocking conditions without mutating. Non-blog drafts always pass.
  defp publish_gate_status(%Draft{content_type: "blog"} = draft) do
    threshold = seo_publish_threshold()
    score = draft.seo_score || 0

    cond do
      draft.research_status == "lost_data_point" -> :blocks
      score < threshold -> :blocks
      true -> :passes
    end
  end

  defp publish_gate_status(_draft), do: :passes

  defp seo_publish_threshold do
    :content_forge
    |> Application.get_env(:seo, [])
    |> Keyword.get(:publish_threshold, 18)
  end

  # --- result ---------------------------------------------------------------

  defp result_from_draft(%Draft{} = draft) do
    %{
      draft_id: draft.id,
      status: draft.status,
      approved_at: iso8601(draft.updated_at),
      approved_via_override: draft.approved_via_override == true,
      override_reason: draft.override_reason
    }
  end

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp iso8601(%NaiveDateTime{} = ndt) do
    ndt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()
  end

  # --- draft lookup ---------------------------------------------------------

  defp fetch_draft(product, params) do
    case binary_param(params, "draft_id") do
      nil -> {:error, :not_found}
      id -> scoped_draft(product, id)
    end
  end

  defp scoped_draft(product, id) do
    case safe_get_draft(id) do
      %Draft{product_id: pid} = draft when pid == product.id -> {:ok, draft}
      _ -> {:error, :not_found}
    end
  end

  defp safe_get_draft(id) do
    ContentGeneration.get_draft(id)
  rescue
    Ecto.Query.CastError -> nil
  end

  # --- helpers --------------------------------------------------------------

  defp binary_param(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end
end
