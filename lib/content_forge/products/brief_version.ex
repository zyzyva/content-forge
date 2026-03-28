defmodule ContentForge.Products.BriefVersion do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "brief_versions" do
    field :version, :integer
    field :content, :string
    field :performance_summary, :map
    field :rewrite_reason, :string

    belongs_to :content_brief, ContentForge.Products.ContentBrief

    timestamps type: :utc_datetime
  end

  def changeset(brief_version, attrs) do
    brief_version
    |> cast(attrs, [
      :content_brief_id,
      :version,
      :content,
      :performance_summary,
      :rewrite_reason
    ])
    |> validate_required([:content_brief_id, :version, :content])
    |> validate_number(:version, greater_than: 0)
  end
end