defmodule ContentForge.Providers do
  @moduledoc """
  Provider-status roll-up for the `/dashboard/providers` panel.

  Every external integration the app depends on gets a single-row
  summary with:

    * `:id` - stable identifier for tests and links.
    * `:name` - human-facing label.
    * `:status` - one of `:available`, `:configured`, `:unavailable`,
      `:degraded`.
    * `:last_success_at` - DateTime of the most recent successful use
      drawn from the relevant audit table (or nil if no trace exists).
    * `:last_error_at` - DateTime of the most recent failure within
      the degrade window (or nil).
    * `:note` - short human-facing explanation (for example the
      env-var name to set, or the count of recent failures).

  The roll-up reads application config for the credential check and
  the existing audit tables (`SmsEvent`, `ProductAsset`, `Draft`) for
  recent-activity signals. It never issues a synthetic call to the
  upstream - a dashboard render must not itself cause a Twilio or
  Anthropic roundtrip.

  ## Status derivation

    * `:unavailable` - credentials are missing.
    * `:degraded` - credentials present AND more than 3 transient
      errors in the last 15 minutes (provider-specific; see each
      `*_status/0` head).
    * `:available` - credentials present AND a successful use in the
      degrade-window or the success-window.
    * `:configured` - credentials present but no recent traffic.

  For providers without a rich audit signal (Apify, OpenClaw) the
  roll-up stops at `:configured` / `:unavailable` since there is no
  sensible way to distinguish "ready" from "hasn't been called yet"
  without probing.
  """

  import Ecto.Query

  alias ContentForge.ContentGeneration.Draft
  alias ContentForge.LLM.Anthropic
  alias ContentForge.LLM.Gemini
  alias ContentForge.MediaForge
  alias ContentForge.OpenClaw
  alias ContentForge.ProductAssets.ProductAsset
  alias ContentForge.Repo
  alias ContentForge.Sms.SmsEvent
  alias ContentForge.Twilio

  @degrade_window_seconds 900
  @degrade_error_threshold 3
  @success_window_seconds 3_600

  @type status :: :available | :configured | :unavailable | :degraded

  @type row :: %{
          id: atom(),
          name: String.t(),
          status: status(),
          last_success_at: DateTime.t() | nil,
          last_error_at: DateTime.t() | nil,
          note: String.t() | nil
        }

  @doc "Returns a list of provider-status rows in a stable display order."
  @spec list_provider_statuses() :: [row()]
  def list_provider_statuses do
    [
      media_forge_status(),
      anthropic_status(),
      gemini_status(),
      open_claw_status(),
      apify_status(),
      twilio_status()
    ]
  end

  @doc """
  Returns a summary of statuses: `%{available: N, configured: N,
  unavailable: N, degraded: N}`. Drives the hub card's compact count.
  """
  @spec summary() :: %{status() => non_neg_integer()}
  def summary do
    list_provider_statuses()
    |> Enum.reduce(%{available: 0, configured: 0, unavailable: 0, degraded: 0}, fn row, acc ->
      Map.update(acc, row.status, 1, &(&1 + 1))
    end)
  end

  # --- Media Forge --------------------------------------------------------

  defp media_forge_status do
    base = %{
      id: :media_forge,
      name: "Media Forge",
      last_success_at: nil,
      last_error_at: nil,
      note: nil
    }

    case MediaForge.status() do
      :not_configured ->
        Map.merge(base, %{status: :unavailable, note: "Set MEDIA_FORGE_SECRET"})

      :ok ->
        last_success = most_recent_asset_at("processed")
        last_error = most_recent_asset_at("failed", window: @degrade_window_seconds)
        errors = count_assets_within("failed", @degrade_window_seconds)

        Map.merge(base, %{
          status: classify(errors, last_success, :processed_asset),
          last_success_at: last_success,
          last_error_at: last_error,
          note: degrade_note(errors)
        })
    end
  end

  defp most_recent_asset_at(status, opts \\ []) do
    query =
      from(a in ProductAsset,
        where: a.status == ^status,
        order_by: [desc: a.updated_at],
        limit: 1,
        select: a.updated_at
      )
      |> apply_window(opts)

    Repo.one(query)
  end

  defp count_assets_within(status, seconds) do
    since = DateTime.add(DateTime.utc_now(), -seconds, :second)

    Repo.aggregate(
      from(a in ProductAsset, where: a.status == ^status and a.updated_at >= ^since),
      :count,
      :id
    )
  end

  defp apply_window(query, []), do: query

  defp apply_window(query, window: seconds) do
    since = DateTime.add(DateTime.utc_now(), -seconds, :second)
    where(query, [a], a.updated_at >= ^since)
  end

  # --- LLM (Anthropic / Gemini) ------------------------------------------

  defp anthropic_status do
    llm_row(
      :anthropic,
      "Anthropic (Claude)",
      Anthropic.status(),
      "anthropic:",
      "ANTHROPIC_API_KEY"
    )
  end

  defp gemini_status do
    llm_row(:gemini, "Gemini", Gemini.status(), "gemini:", "GEMINI_API_KEY")
  end

  defp llm_row(id, name, provider_status, model_prefix, env_var) do
    base = %{id: id, name: name, last_success_at: nil, last_error_at: nil, note: nil}

    case provider_status do
      :not_configured ->
        Map.merge(base, %{status: :unavailable, note: "Set #{env_var}"})

      :ok ->
        last_success = most_recent_draft_at(model_prefix)
        errors = 0

        Map.merge(base, %{
          status: classify(errors, last_success, :draft),
          last_success_at: last_success
        })
    end
  end

  defp most_recent_draft_at(model_prefix) do
    like = model_prefix <> "%"

    Repo.one(
      from(d in Draft,
        where: like(d.generating_model, ^like),
        order_by: [desc: d.inserted_at],
        limit: 1,
        select: d.inserted_at
      )
    )
  end

  # --- OpenClaw -----------------------------------------------------------

  defp open_claw_status do
    base = %{
      id: :open_claw,
      name: "OpenClaw",
      last_success_at: nil,
      last_error_at: nil,
      note: nil
    }

    case OpenClaw.status() do
      :not_configured ->
        Map.merge(base, %{
          status: :unavailable,
          note: "Set OPENCLAW_BASE_URL + OPENCLAW_API_KEY"
        })

      :ok ->
        Map.put(base, :status, :configured)
    end
  end

  # --- Apify --------------------------------------------------------------

  defp apify_status do
    base = %{id: :apify, name: "Apify", last_success_at: nil, last_error_at: nil, note: nil}
    token = get_in(Application.get_env(:content_forge, :apify, []), [:token])

    case token do
      t when is_binary(t) and t != "" ->
        Map.put(base, :status, :configured)

      _ ->
        Map.merge(base, %{status: :unavailable, note: "Set APIFY_TOKEN"})
    end
  end

  # --- Twilio -------------------------------------------------------------

  defp twilio_status do
    base = %{id: :twilio, name: "Twilio", last_success_at: nil, last_error_at: nil, note: nil}

    case Twilio.status() do
      :not_configured ->
        Map.merge(base, %{
          status: :unavailable,
          note: "Set TWILIO_ACCOUNT_SID + TWILIO_AUTH_TOKEN + TWILIO_FROM_NUMBER"
        })

      :ok ->
        last_success = most_recent_outbound_at(["sent", "delivered"])
        last_error = most_recent_outbound_at(["failed"], window: @degrade_window_seconds)
        errors = count_outbound_within("failed", @degrade_window_seconds)

        Map.merge(base, %{
          status: classify(errors, last_success, :outbound_sms),
          last_success_at: last_success,
          last_error_at: last_error,
          note: degrade_note(errors)
        })
    end
  end

  defp most_recent_outbound_at(statuses, opts \\ []) do
    query =
      from(e in SmsEvent,
        where: e.direction == "outbound" and e.status in ^statuses,
        order_by: [desc: e.inserted_at],
        limit: 1,
        select: e.inserted_at
      )
      |> apply_event_window(opts)

    Repo.one(query)
  end

  defp count_outbound_within(status, seconds) do
    since = DateTime.add(DateTime.utc_now(), -seconds, :second)

    Repo.aggregate(
      from(e in SmsEvent,
        where:
          e.direction == "outbound" and
            e.status == ^status and
            e.inserted_at >= ^since
      ),
      :count,
      :id
    )
  end

  defp apply_event_window(query, []), do: query

  defp apply_event_window(query, window: seconds) do
    since = DateTime.add(DateTime.utc_now(), -seconds, :second)
    where(query, [e], e.inserted_at >= ^since)
  end

  # --- classification helpers --------------------------------------------

  defp classify(errors, _last_success, _kind) when errors > @degrade_error_threshold,
    do: :degraded

  defp classify(_errors, nil, _kind), do: :configured

  defp classify(_errors, %DateTime{} = last_success, _kind) do
    if recent?(last_success, @success_window_seconds), do: :available, else: :configured
  end

  defp recent?(%DateTime{} = dt, seconds) do
    DateTime.diff(DateTime.utc_now(), dt, :second) <= seconds
  end

  defp degrade_note(errors) when errors > @degrade_error_threshold,
    do: "#{errors} errors in the last 15 min"

  defp degrade_note(_), do: nil
end
