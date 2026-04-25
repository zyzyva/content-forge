defmodule ContentForge.OpenClawTools.ScheduleReminderChange do
  @moduledoc """
  OpenClaw tool: updates a product's `ReminderConfig` cadence /
  enabled flag behind the 16.4 two-turn confirmation envelope.

  Authorization: requires `:owner` on the resolved product.

  Params (required):

    * `"cadence_days"` - integer in 1..30. Outside the range
      returns `:invalid_cadence`.

  Params (optional):

    * `"enabled"` - boolean, default `true`. Non-boolean values
      return `:invalid_enabled`.
    * `"product"` - resolved via `ProductResolver`. SMS callers
      can omit once a phone is registered.
    * `"confirm"` - echo phrase from the first-turn envelope.

  Flow:

    1. Resolve product.
    2. `Authorization.require(ctx, :owner)`.
    3. Validate cadence + enabled shape up front.
    4. Fetch the current config (schema defaults when no row
       exists yet). Compare with the requested values. If
       nothing would change, short-circuit with
       `{:ok, %{changed: false, ...}}` so the user does not have
       to confirm a no-op.
    5. Otherwise: first call (no `"confirm"`) hands back a
       confirmation envelope whose preview carries the
       before / after diff; second call (with `"confirm"`) runs
       `Confirmation.confirm/4` and, on success, upserts the
       config via `Sms.upsert_reminder_config/2`.

  Returns `%{changed: boolean, product_id, cadence_days, enabled}`
  on a no-op or after a successful change (the latter includes
  `updated_at`), or `{:ok, :confirmation_required, envelope}` on
  the first turn.

  Errors: `:missing_product_context`, `:product_not_found`,
  `:ambiguous_product`, `:forbidden`, `:invalid_cadence`,
  `:invalid_enabled`, `:update_failed`, plus the standard
  confirmation reasons (`:missing_session`,
  `:confirmation_not_found`, `:confirmation_mismatch`,
  `:confirmation_expired`).
  """

  alias ContentForge.OpenClawTools.Authorization
  alias ContentForge.OpenClawTools.Confirmation
  alias ContentForge.OpenClawTools.ProductResolver
  alias ContentForge.Sms
  alias ContentForge.Sms.ReminderConfig

  @tool_name "schedule_reminder_change"
  @cadence_min 1
  @cadence_max 30

  @spec call(map(), map()) ::
          {:ok, map()} | {:ok, :confirmation_required, map()} | {:error, term()}
  def call(ctx, params) when is_map(params) do
    with {:ok, product} <- ProductResolver.resolve(ctx, params),
         :ok <- Authorization.require(Map.put(ctx, :product, product), :owner),
         {:ok, cadence} <- fetch_cadence(params),
         {:ok, enabled} <- fetch_enabled(params) do
      dispatch_turn(ctx, params, product, cadence, enabled)
    end
  end

  # --- turn dispatch --------------------------------------------------------

  defp dispatch_turn(ctx, params, product, cadence, enabled) do
    current = Sms.get_reminder_config(product.id)

    if same?(current, cadence, enabled) do
      {:ok, %{changed: false, product_id: product.id, cadence_days: cadence, enabled: enabled}}
    else
      case binary_param(params, "confirm") do
        nil -> request_turn(ctx, params, product, current, cadence, enabled)
        echo -> confirm_turn(ctx, params, product, cadence, enabled, echo)
      end
    end
  end

  defp request_turn(ctx, params, product, current, cadence, enabled) do
    preview = build_preview(product, current, cadence, enabled)

    case Confirmation.request(@tool_name, ctx, params, preview) do
      {:ok, envelope} -> {:ok, :confirmation_required, envelope}
      {:error, _} = err -> err
    end
  end

  defp confirm_turn(ctx, params, product, cadence, enabled, echo) do
    with :ok <- Confirmation.confirm(@tool_name, ctx, params, echo),
         {:ok, row} <-
           Sms.upsert_reminder_config(product.id, %{cadence_days: cadence, enabled: enabled}) do
      {:ok,
       %{
         changed: true,
         product_id: product.id,
         cadence_days: row.cadence_days,
         enabled: row.enabled,
         updated_at: iso8601(row.updated_at)
       }}
    else
      {:error, %Ecto.Changeset{}} -> {:error, :update_failed}
      {:error, _} = err -> err
    end
  end

  # --- diff + preview -------------------------------------------------------

  defp same?(%ReminderConfig{cadence_days: c, enabled: e}, cadence, enabled),
    do: c == cadence and e == enabled

  defp build_preview(product, current, cadence, enabled) do
    %{
      summary:
        "Change reminders for #{product.name} from " <>
          describe(current.cadence_days, current.enabled) <>
          " to " <>
          describe(cadence, enabled) <>
          ".",
      product_id: product.id,
      before: %{cadence_days: current.cadence_days, enabled: current.enabled},
      after: %{cadence_days: cadence, enabled: enabled}
    }
  end

  defp describe(_cadence, false), do: "off"
  defp describe(cadence, true) when cadence == 1, do: "daily"
  defp describe(cadence, true), do: "every #{cadence} days"

  # --- param validation -----------------------------------------------------

  defp fetch_cadence(params) do
    case Map.get(params, "cadence_days") do
      n when is_integer(n) and n >= @cadence_min and n <= @cadence_max -> {:ok, n}
      _ -> {:error, :invalid_cadence}
    end
  end

  defp fetch_enabled(params) do
    case Map.get(params, "enabled", true) do
      value when is_boolean(value) -> {:ok, value}
      _ -> {:error, :invalid_enabled}
    end
  end

  # --- helpers --------------------------------------------------------------

  defp binary_param(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp iso8601(%NaiveDateTime{} = ndt) do
    ndt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()
  end
end
