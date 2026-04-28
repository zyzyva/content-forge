defmodule ContentForgeWeb.EscalationController do
  @moduledoc """
  Phase 16.6 REST surface for resolving escalations.

  Route: `POST /api/v1/escalations/:id/resolve`

  Auth: standard `:api_auth` bearer-token pipeline. Body accepts
  an optional `resolved_by` string; defaults to the API key
  label associated with the bearer token.

  When the escalation row's `channel` is `"sms"`, the controller
  also calls `ContentForge.Sms.resolve_session/1` to clear the
  paused auto-response flag on the matching `ConversationSession`
  (preserving the 14.5 dashboard behavior so the operator does
  not have to resolve in two places).
  """

  use ContentForgeWeb, :controller

  alias ContentForge.Escalations
  alias ContentForge.Escalations.EscalationEvent
  alias ContentForge.Repo
  alias ContentForge.Sms
  alias ContentForge.Sms.ConversationSession

  action_fallback ContentForgeWeb.FallbackController

  def resolve(conn, %{"id" => id} = params) do
    case Escalations.get(id) do
      nil ->
        {:error, :not_found}

      %EscalationEvent{} = event ->
        resolved_by = resolved_by_for(conn, params)

        case Escalations.mark_resolved(event, resolved_by) do
          {:ok, updated} ->
            _ = maybe_resume_sms_session(updated)
            render(conn, :show, event: updated)

          {:error, %Ecto.Changeset{}} = err ->
            err
        end
    end
  end

  defp resolved_by_for(conn, params) do
    case Map.get(params, "resolved_by") do
      label when is_binary(label) and label != "" ->
        label

      _ ->
        case conn.assigns[:api_key] do
          %{label: label} when is_binary(label) and label != "" -> label
          _ -> "api"
        end
    end
  end

  defp maybe_resume_sms_session(%EscalationEvent{channel: "sms", session_id: session_id}) do
    case Repo.get(ConversationSession, session_id) do
      nil -> :ok
      %ConversationSession{} = session -> Sms.resolve_session(session)
    end
  end

  defp maybe_resume_sms_session(_event), do: :ok
end
