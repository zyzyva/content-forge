defmodule ContentForge.Sms.ReminderConfig do
  @moduledoc """
  Per-product reminder configuration: cadence, quiet-hours window,
  timezone, and ignore-based backoff/stop thresholds.

  Exactly one row per product (composite unique on `product_id` alone,
  and `belongs_to :product` cascades on product delete). Callers that
  want defaults without persisting a row should go through
  `ContentForge.Sms.get_reminder_config/1`, which returns a struct with
  schema defaults when no row exists.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "sms_reminder_configs" do
    field :enabled, :boolean, default: true
    field :cadence_days, :integer, default: 7
    field :quiet_hours_start, :integer, default: 20
    field :quiet_hours_end, :integer, default: 8
    field :timezone, :string, default: "UTC"
    field :backoff_after_ignored, :integer, default: 2
    field :stop_after_ignored, :integer, default: 4

    belongs_to :product, ContentForge.Products.Product

    timestamps(type: :utc_datetime)
  end

  @required ~w(product_id)a
  @optional ~w(enabled cadence_days quiet_hours_start quiet_hours_end timezone backoff_after_ignored stop_after_ignored)a

  def changeset(row, attrs) do
    row
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_number(:cadence_days, greater_than: 0)
    |> validate_number(:quiet_hours_start, greater_than_or_equal_to: 0, less_than_or_equal_to: 23)
    |> validate_number(:quiet_hours_end, greater_than_or_equal_to: 0, less_than_or_equal_to: 23)
    |> validate_number(:backoff_after_ignored, greater_than: 0)
    |> validate_number(:stop_after_ignored, greater_than: 0)
    |> foreign_key_constraint(:product_id)
    |> unique_constraint(:product_id,
      name: :sms_reminder_configs_product_id_index,
      message: "reminder config already exists for this product"
    )
  end
end
