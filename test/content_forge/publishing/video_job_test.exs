defmodule ContentForge.Publishing.VideoJobTest do
  use ExUnit.Case, async: true

  alias ContentForge.Publishing.VideoJob

  describe "changeset/2" do
    test "creates valid changeset with required fields" do
      attrs = %{
        draft_id: Ecto.UUID.generate(),
        product_id: Ecto.UUID.generate()
      }

      changeset = VideoJob.changeset(%VideoJob{}, attrs)

      assert changeset.valid?
      assert changeset.changes.draft_id == attrs.draft_id
      assert changeset.changes.product_id == attrs.product_id
      # Status uses schema default, not changeset default
      assert changeset.data.status == "script_approved"
    end

    test "validates status inclusion" do
      attrs = %{
        draft_id: Ecto.UUID.generate(),
        product_id: Ecto.UUID.generate(),
        status: "invalid_status"
      }

      changeset = VideoJob.changeset(%VideoJob{}, attrs)

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).status
    end

    test "allows all valid status values" do
      statuses = [
        "script_approved",
        "voiceover_done",
        "recording_done",
        "avatar_done",
        "assembled",
        "uploaded",
        "failed",
        "paused"
      ]

      for status <- statuses do
        attrs = %{
          draft_id: Ecto.UUID.generate(),
          product_id: Ecto.UUID.generate(),
          status: status
        }

        changeset = VideoJob.changeset(%VideoJob{}, attrs)
        assert changeset.valid?, "Expected #{status} to be valid"
      end
    end
  end

  describe "status_changeset/2" do
    test "clears error when status changes" do
      video_job = %VideoJob{
        draft_id: Ecto.UUID.generate(),
        product_id: Ecto.UUID.generate(),
        error: "Previous error"
      }

      changeset = VideoJob.status_changeset(video_job, %{
        status: "voiceover_done",
        per_step_r2_keys: %{"voiceover" => "test_key.mp3"}
      })

      assert changeset.valid?
      assert changeset.changes.status == "voiceover_done"
      assert is_nil(changeset.changes.error)
    end
  end

  describe "status predicates" do
    test "script_approved?/1 returns true for script_approved status" do
      video_job = %VideoJob{status: "script_approved"}
      assert VideoJob.script_approved?(video_job) == true
      refute VideoJob.voiceover_done?(video_job)
    end

    test "voiceover_done?/1 returns true for voiceover_done status" do
      video_job = %VideoJob{status: "voiceover_done"}
      assert VideoJob.voiceover_done?(video_job) == true
      refute VideoJob.assembled?(video_job)
    end

    test "uploaded?/1 returns true for uploaded status" do
      video_job = %VideoJob{status: "uploaded"}
      assert VideoJob.uploaded?(video_job) == true
    end

    test "failed?/1 returns true for failed status" do
      video_job = %VideoJob{status: "failed"}
      assert VideoJob.failed?(video_job) == true
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Map.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end