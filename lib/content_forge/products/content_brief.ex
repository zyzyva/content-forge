defmodule ContentForge.Products.ContentBrief do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "content_briefs" do
    field :version, :integer
    field :content, :string
    field :snapshot_id, :binary_id
    field :competitor_intel_id, :binary_id
    field :performance_summary, :map
    field :model_used, :string

    belongs_to :product, ContentForge.Products.Product
    has_many :brief_versions, ContentForge.Products.BriefVersion, on_delete: :delete_all
    has_many :drafts, ContentForge.ContentGeneration.Draft

    timestamps type: :utc_datetime
  end

  def changeset(content_brief, attrs) do
    content_brief
    |> cast(attrs, [
      :product_id,
      :version,
      :content,
      :snapshot_id,
      :competitor_intel_id,
      :performance_summary,
      :model_used
    ])
    |> validate_required([:product_id, :version, :content])
    |> validate_number(:version, greater_than: 0)
  end
end
