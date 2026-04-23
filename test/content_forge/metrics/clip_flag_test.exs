defmodule ContentForge.Metrics.ClipFlagTest do
  use ContentForge.DataCase, async: true

  alias ContentForge.Metrics.ClipFlag

  defp valid_attrs(overrides) do
    Map.merge(
      %{
        video_id: Ecto.UUID.generate(),
        video_platform_id: "yt_abc123",
        platform: "youtube",
        start_seconds: 10,
        end_seconds: 30
      },
      overrides
    )
  end

  describe "changeset/2" do
    test "with end_seconds <= start_seconds returns invalid changeset" do
      attrs = valid_attrs(%{start_seconds: 30, end_seconds: 30})
      changeset = ClipFlag.changeset(%ClipFlag{}, attrs)
      assert changeset.valid? == false
      errors = ContentForge.DataCase.errors_on(changeset)
      assert Map.has_key?(errors, :end_seconds)
    end

    test "with end_seconds less than start_seconds returns invalid changeset" do
      attrs = valid_attrs(%{start_seconds: 50, end_seconds: 20})
      changeset = ClipFlag.changeset(%ClipFlag{}, attrs)
      assert changeset.valid? == false
      errors = ContentForge.DataCase.errors_on(changeset)
      assert Map.has_key?(errors, :end_seconds)
    end

    test "with valid start and end seconds returns valid changeset" do
      attrs = valid_attrs(%{start_seconds: 10, end_seconds: 30})
      changeset = ClipFlag.changeset(%ClipFlag{}, attrs)
      assert changeset.valid? == true
    end
  end

  describe "from_youtube_retention/3" do
    test "with a retention curve containing a high-engagement segment returns at least one clip flag" do
      video_id = Ecto.UUID.generate()
      platform_id = "yt_test_video"

      # Build a retention curve where a segment clearly exceeds 1.2x the average.
      # Average of these values is (10+11+12+90+91+92+11+10+10+10) / 10 = 34.7
      # The 90/91/92 window is well above 1.2 * 34.7 = 41.6
      retention_curve = %{
        "data" => [
          %{"time" => "0", "value" => "10.0"},
          %{"time" => "5", "value" => "11.0"},
          %{"time" => "10", "value" => "12.0"},
          %{"time" => "15", "value" => "90.0"},
          %{"time" => "20", "value" => "91.0"},
          %{"time" => "25", "value" => "92.0"},
          %{"time" => "30", "value" => "11.0"},
          %{"time" => "35", "value" => "10.0"},
          %{"time" => "40", "value" => "10.0"},
          %{"time" => "45", "value" => "10.0"}
        ]
      }

      result = ClipFlag.from_youtube_retention(video_id, platform_id, retention_curve)
      assert {:ok, flags} = result
      assert length(flags) >= 1

      Enum.each(flags, fn flag ->
        assert flag.valid? == true
      end)
    end
  end
end
