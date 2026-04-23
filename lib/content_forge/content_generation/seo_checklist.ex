defmodule ContentForge.ContentGeneration.SeoChecklist do
  @moduledoc """
  Stores the result of running the 28-point SEO checklist against
  a blog draft. One row per draft (unique fk); re-running
  replaces the row via upsert.

  Fields:

    * `results` - a map keyed by check name (string), value is a
      map with `"status"` (`"pass"` | `"fail"` | `"not_applicable"`)
      and an optional `"note"` string.
    * `score` - integer count of `"pass"` results out of non-
      applicable total. The denominator is implicit (callers can
      subtract not_applicable from 28 to get the graded total).
    * `run_at` - when the runner wrote this row.

  Shipped in Phase 12.2a with the infrastructure + 4 real checks.
  12.2b and 12.2c land the remaining 24 checks.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "seo_checklists" do
    field :results, :map, default: %{}
    field :score, :integer, default: 0
    field :run_at, :utc_datetime_usec

    belongs_to :draft, ContentForge.ContentGeneration.Draft

    timestamps type: :utc_datetime
  end

  def changeset(checklist, attrs) do
    checklist
    |> cast(attrs, [:draft_id, :results, :score, :run_at])
    |> validate_required([:draft_id, :results, :score, :run_at])
    |> assoc_constraint(:draft)
    |> unique_constraint(:draft_id)
  end
end
