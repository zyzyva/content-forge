defmodule ContentForge.ContentGeneration.Draft do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "drafts" do
    field :content, :string
    field :platform, :string
    field :content_type, :string
    field :angle, :string
    field :generating_model, :string
    field :raw_response, :string
    field :status, :string
    field :image_url, :string
    field :media_forge_job_id, :string
    field :error, :string

    belongs_to :product, ContentForge.Products.Product
    belongs_to :content_brief, ContentForge.Products.ContentBrief

    belongs_to :repurposed_from, ContentForge.ContentGeneration.Draft,
      foreign_key: :repurposed_from_id

    has_many :draft_scores, ContentForge.ContentGeneration.DraftScore, on_delete: :delete_all

    timestamps type: :utc_datetime
  end

  def changeset(draft, attrs) do
    draft
    |> cast(attrs, [
      :product_id,
      :content_brief_id,
      :content,
      :platform,
      :content_type,
      :angle,
      :generating_model,
      :raw_response,
      :status,
      :repurposed_from_id,
      :image_url,
      :media_forge_job_id,
      :error
    ])
    |> validate_required([:product_id, :content, :platform, :content_type, :generating_model])
    |> validate_inclusion(:platform, ~w(twitter linkedin reddit facebook instagram blog youtube))
    |> validate_inclusion(:content_type, ~w(post blog video_script))
    |> validate_inclusion(:status, ~w(draft ranked approved rejected published blocked))
    |> validate_inclusion(
      :angle,
      ~w(educational entertaining problem_aware social_proof humor testimonial case_study how_to listicle),
      allow_nil: true
    )
    |> put_default_status()
  end

  defp put_default_status(changeset) do
    case get_field(changeset, :status) do
      nil -> put_change(changeset, :status, "draft")
      _ -> changeset
    end
  end
end
