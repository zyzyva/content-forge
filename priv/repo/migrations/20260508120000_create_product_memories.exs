defmodule ContentForge.Repo.Migrations.CreateProductMemories do
  use Ecto.Migration

  def change do
    # Conversation-derived notes attached to a product. The OpenClaw
    # agent writes rows through the `record_memory` tool (16.3d) so
    # future conversations can recall persistent context the user
    # shared. Cascade on product delete: a gone product's memories
    # are moot.
    create table(:product_memories, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :product_id,
          references(:products, type: :binary_id, on_delete: :delete_all),
          null: false

      add :session_id, :string, null: false
      add :channel, :string, null: false
      add :sender_identity, :string
      add :content, :text, null: false
      add :tags, {:array, :string}, null: false, default: []

      timestamps(type: :utc_datetime)
    end

    create index(:product_memories, [:product_id])
    create index(:product_memories, [:product_id, :inserted_at])
  end
end
