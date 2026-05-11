defmodule ContentForge.Repo.Migrations.AddAudienceSignalsAndWindowToCompetitorIntel do
  use Ecto.Migration

  def change do
    # Phase 17.3 pre-empts the Phase 17.4 schema work so the
    # `cf_store_intel` MCP tool can persist every documented param
    # honestly. The 17.4 synthesizer will populate the new columns
    # autonomously when it runs comment-aware syntheses.
    alter table(:competitor_intel) do
      add :audience_signals, {:array, :string}, null: false, default: []
      add :window, :string
    end

    create index(:competitor_intel, [:window])
  end
end
