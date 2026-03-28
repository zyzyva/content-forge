defmodule ContentForge.Publishing.EngagementMetric do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "engagement_metrics" do
    field :platform, :string
    field :hour_of_day, :integer
    field :day_of_week, :integer
    field :total_posts, :integer
    field :total_engagement, :integer
    field :avg_engagement, :float
    field :last_calculated_at, :utc_datetime

    belongs_to :product, ContentForge.Products.Product

    timestamps type: :utc_datetime
  end

  def changeset(engagement_metric, attrs) do
    engagement_metric
    |> cast(attrs, [
      :product_id,
      :platform,
      :hour_of_day,
      :day_of_week,
      :total_posts,
      :total_engagement,
      :avg_engagement,
      :last_calculated_at
    ])
    |> validate_required([:product_id, :platform, :hour_of_day, :day_of_week])
    |> validate_inclusion(:platform, ~w(twitter linkedin reddit facebook instagram))
    |> validate_inclusion(:hour_of_day, 0..23)
    |> validate_inclusion(:day_of_week, 1..7)
    |> calculate_avg_engagement()
  end

  defp calculate_avg_engagement(changeset) do
    total_posts = get_change(changeset, :total_posts) || get_field(changeset, :total_posts) || 0

    total_engagement =
      get_change(changeset, :total_engagement) || get_field(changeset, :total_engagement) || 0

    if total_posts > 0 do
      put_change(changeset, :avg_engagement, total_engagement / total_posts)
    else
      changeset
    end
  end
end
