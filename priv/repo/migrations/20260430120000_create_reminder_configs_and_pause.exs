defmodule ContentForge.Repo.Migrations.CreateReminderConfigsAndPause do
  use Ecto.Migration

  def change do
    create table(:sms_reminder_configs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :product_id,
          references(:products, type: :binary_id, on_delete: :delete_all),
          null: false

      add :enabled, :boolean, null: false, default: true
      add :cadence_days, :integer, null: false, default: 7
      add :quiet_hours_start, :integer, null: false, default: 20
      add :quiet_hours_end, :integer, null: false, default: 8
      add :timezone, :string, null: false, default: "UTC"
      add :backoff_after_ignored, :integer, null: false, default: 2
      add :stop_after_ignored, :integer, null: false, default: 4

      timestamps(type: :utc_datetime)
    end

    create unique_index(:sms_reminder_configs, [:product_id],
             name: :sms_reminder_configs_product_id_index
           )

    alter table(:product_phones) do
      add :reminders_paused_until, :utc_datetime_usec
    end
  end
end
