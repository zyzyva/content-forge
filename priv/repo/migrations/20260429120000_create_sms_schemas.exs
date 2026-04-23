defmodule ContentForge.Repo.Migrations.CreateSmsSchemas do
  use Ecto.Migration

  def change do
    # ---- product_phones ---------------------------------------------------
    # Whitelist of phone numbers authorized to message a product's inbox.
    # Cascade on product delete: the whitelist travels with the product.
    create table(:product_phones, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :product_id,
          references(:products, type: :binary_id, on_delete: :delete_all),
          null: false

      add :phone_number, :string, null: false
      add :role, :string, null: false
      add :display_label, :string
      add :active, :boolean, null: false, default: true
      add :opt_in_at, :utc_datetime_usec
      add :opt_in_source, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:product_phones, [:product_id, :phone_number],
             name: :product_phones_product_id_phone_number_index
           )

    create index(:product_phones, [:phone_number])

    # ---- sms_events -------------------------------------------------------
    # Audit log. product_id nilifies on product delete so the audit row
    # survives a product being removed. phone_number is always captured
    # inline so events remain useful for forensics even after nilify.
    create table(:sms_events, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :product_id,
          references(:products, type: :binary_id, on_delete: :nilify_all)

      add :phone_number, :string, null: false
      add :direction, :string, null: false
      add :body, :text
      add :media_urls, {:array, :string}, null: false, default: []
      add :status, :string, null: false
      add :twilio_sid, :string

      timestamps(type: :utc_datetime_usec)
    end

    create index(:sms_events, [:product_id])
    create index(:sms_events, [:phone_number])
    create index(:sms_events, [:twilio_sid])

    # ---- conversation_sessions -------------------------------------------
    # State machine per (product, phone_number). Cascade on product
    # delete: a product gone means its conversations are moot.
    create table(:conversation_sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :product_id,
          references(:products, type: :binary_id, on_delete: :delete_all),
          null: false

      add :phone_number, :string, null: false
      add :state, :string, null: false, default: "idle"
      add :last_message_at, :utc_datetime_usec
      add :inactive_after_seconds, :integer, null: false, default: 3600

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:conversation_sessions, [:product_id, :phone_number],
             name: :conversation_sessions_product_id_phone_number_index
           )

    create index(:conversation_sessions, [:phone_number])
  end
end
