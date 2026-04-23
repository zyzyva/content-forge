defmodule ContentForge.Repo.Migrations.AddEscalationToConversationSessions do
  use Ecto.Migration

  def change do
    alter table(:conversation_sessions) do
      add :escalated_at, :utc_datetime_usec
      add :escalation_reason, :text
      add :auto_response_paused, :boolean, null: false, default: false
    end

    create index(:conversation_sessions, [:escalated_at])
  end
end
