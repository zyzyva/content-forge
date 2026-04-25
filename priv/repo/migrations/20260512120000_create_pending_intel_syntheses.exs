defmodule ContentForge.Repo.Migrations.CreatePendingIntelSyntheses do
  use Ecto.Migration

  def change do
    # Phase 17.4 without-key route. When no ANTHROPIC_API_KEY is
    # configured the synthesizer cannot run the autonomous LLM
    # synthesis; instead it inserts one of these rows so a Claude
    # Code session (via the MCP server) knows there is a synthesis
    # waiting to be completed by hand. cf_store_intel resolves the
    # row when the manual synthesis is persisted.
    create table(:pending_intel_syntheses, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :product_id,
          references(:products, type: :binary_id, on_delete: :delete_all),
          null: false

      add :window, :string
      add :source_post_ids, {:array, :binary_id}, null: false, default: []
      add :note, :string

      timestamps(type: :utc_datetime)
    end

    create index(:pending_intel_syntheses, [:product_id])
    create index(:pending_intel_syntheses, [:product_id, :window])
  end
end
