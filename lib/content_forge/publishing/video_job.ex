defmodule ContentForge.Publishing.VideoJob do
  @moduledoc """
  Schema for tracking video production jobs through the pipeline.
  Each job represents a video being produced from a draft (script).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(
    script_approved
    voiceover_done
    recording_done
    avatar_done
    assembled
    encoded
    uploaded
    failed
    paused
  )

  schema "video_jobs" do
    field :status, :string, default: "script_approved"
    field :per_step_r2_keys, :map
    field :error, :string
    field :feature_flag, :boolean, default: true
    field :media_forge_job_id, :string
    field :promoted_via_override, :boolean, default: false
    field :promoted_score, :float
    field :promoted_threshold, :float
    field :published_platforms, {:array, :string}, default: []

    belongs_to :draft, ContentForge.ContentGeneration.Draft
    belongs_to :product, ContentForge.Products.Product

    timestamps type: :utc_datetime
  end

  def changeset(video_job, attrs) do
    video_job
    |> cast(attrs, [
      :draft_id,
      :product_id,
      :status,
      :per_step_r2_keys,
      :error,
      :feature_flag,
      :media_forge_job_id,
      :promoted_via_override,
      :promoted_score,
      :promoted_threshold,
      :published_platforms
    ])
    |> validate_required([:draft_id, :product_id])
    |> validate_inclusion(:status, @statuses)
  end

  def status_changeset(video_job, attrs) do
    video_job
    |> cast(attrs, [:status, :per_step_r2_keys, :error, :media_forge_job_id, :published_platforms])
    |> validate_inclusion(:status, @statuses)
    |> clear_error_on_status_change()
  end

  @doc """
  Lightweight changeset for updating published_platforms only.
  Called after each platform publish completes.
  """
  def publish_update(video_job, platform) do
    current = video_job.published_platforms || []

    video_job
    |> change(%{published_platforms: Enum.uniq([platform | current])})
  end

  defp clear_error_on_status_change(changeset) do
    case get_change(changeset, :status) do
      nil -> changeset
      _ -> put_change(changeset, :error, nil)
    end
  end

  # Status predicates
  def script_approved?(%__MODULE__{status: "script_approved"}), do: true
  def script_approved?(_), do: false

  def voiceover_done?(%__MODULE__{status: "voiceover_done"}), do: true
  def voiceover_done?(_), do: false

  def recording_done?(%__MODULE__{status: "recording_done"}), do: true
  def recording_done?(_), do: false

  def avatar_done?(%__MODULE__{status: "avatar_done"}), do: true
  def avatar_done?(_), do: false

  def assembled?(%__MODULE__{status: "assembled"}), do: true
  def assembled?(_), do: false

  def encoded?(%__MODULE__{status: "encoded"}), do: true
  def encoded?(_), do: false

  def uploaded?(%__MODULE__{status: "uploaded"}), do: true
  def uploaded?(_), do: false

  # Nil-safe: the migration backfills `[]` for pre-existing
  # rows, but a row loaded from a partial-column select or a
  # raw insert that bypasses the changeset could still surface
  # `nil`. Defaulting to `[]` keeps the predicate honest.
  def published_to?(%__MODULE__{published_platforms: nil}, _platform), do: false

  def published_to?(%__MODULE__{published_platforms: platforms}, platform)
      when is_list(platforms),
      do: platform in platforms

  def failed?(%__MODULE__{status: "failed"}), do: true
  def failed?(_), do: false

  def paused?(%__MODULE__{status: "paused"}), do: true
  def paused?(_), do: false
end
