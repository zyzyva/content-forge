defmodule ContentForge.CompetitorResearchTest do
  @moduledoc """
  Phase 17.1: viral threshold + rolling-average helpers shared by
  the scrape + harvester pipelines. Pure functions so the test is
  fast and deterministic.
  """
  use ExUnit.Case, async: false

  alias ContentForge.CompetitorResearch
  alias ContentForge.Products.CompetitorPost

  setup do
    original = Application.get_env(:content_forge, :competitor_research)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:content_forge, :competitor_research)
      else
        Application.put_env(:content_forge, :competitor_research, original)
      end
    end)

    :ok
  end

  describe "viral?/2" do
    test "returns false below both axes" do
      Application.put_env(:content_forge, :competitor_research,
        viral_views_multiplier: 5,
        viral_views_floor: 100_000
      )

      post = %CompetitorPost{views_count: 10_000}
      assert CompetitorResearch.viral?(post, 5_000) == false
    end

    test "returns true at the absolute floor regardless of rolling avg" do
      Application.put_env(:content_forge, :competitor_research,
        viral_views_multiplier: 5,
        viral_views_floor: 100_000
      )

      post = %CompetitorPost{views_count: 100_000}
      assert CompetitorResearch.viral?(post, 0) == true
    end

    test "returns true above the rolling-multiplier threshold" do
      Application.put_env(:content_forge, :competitor_research,
        viral_views_multiplier: 5,
        viral_views_floor: 100_000
      )

      post = %CompetitorPost{views_count: 50_000}
      # 5x rolling avg of 9_000 = 45_000; 50_000 clears it.
      assert CompetitorResearch.viral?(post, 9_000) == true
    end

    test "ignores the multiplier path when rolling_avg is 0" do
      Application.put_env(:content_forge, :competitor_research,
        viral_views_multiplier: 5,
        viral_views_floor: 100_000
      )

      post = %CompetitorPost{views_count: 50_000}
      assert CompetitorResearch.viral?(post, 0) == false
    end

    test "non-positive views never trip" do
      assert CompetitorResearch.viral?(%CompetitorPost{views_count: 0}, 1_000_000) == false
      assert CompetitorResearch.viral?(%CompetitorPost{views_count: nil}, 1_000_000) == false
    end

    test "honors a custom multiplier from config" do
      Application.put_env(:content_forge, :competitor_research,
        viral_views_multiplier: 10,
        viral_views_floor: 100_000
      )

      post = %CompetitorPost{views_count: 50_000}
      # 10x of 9_000 = 90_000; 50_000 below.
      assert CompetitorResearch.viral?(post, 9_000) == false

      # 10x of 6_000 = 60_000; 50_000 still below.
      assert CompetitorResearch.viral?(post, 6_000) == false

      # 10x of 4_000 = 40_000; 50_000 above.
      assert CompetitorResearch.viral?(post, 4_000) == true
    end

    test "honors a custom floor from config" do
      Application.put_env(:content_forge, :competitor_research,
        viral_views_multiplier: 5,
        viral_views_floor: 25_000
      )

      assert CompetitorResearch.viral?(%CompetitorPost{views_count: 25_000}, 0) == true
      assert CompetitorResearch.viral?(%CompetitorPost{views_count: 24_999}, 0) == false
    end

    test "accepts a plain map with views_count too" do
      Application.put_env(:content_forge, :competitor_research, viral_views_floor: 100_000)
      assert CompetitorResearch.viral?(%{views_count: 100_000}, 0) == true
      assert CompetitorResearch.viral?(%{"views_count" => 100_000}, 0) == true
    end
  end

  describe "max_comments_per_viral_post/0" do
    test "defaults to 50" do
      Application.delete_env(:content_forge, :competitor_research)
      assert CompetitorResearch.max_comments_per_viral_post() == 50
    end

    test "honors a custom override" do
      Application.put_env(:content_forge, :competitor_research, max_comments_per_viral_post: 25)
      assert CompetitorResearch.max_comments_per_viral_post() == 25
    end
  end

  describe "rolling_avg_views/1" do
    test "returns 0.0 for an empty list" do
      assert CompetitorResearch.rolling_avg_views([]) == 0.0
    end

    test "averages views across a mixed-views list" do
      posts = [
        %CompetitorPost{views_count: 1_000},
        %CompetitorPost{views_count: 2_000},
        %CompetitorPost{views_count: 3_000}
      ]

      assert CompetitorResearch.rolling_avg_views(posts) == 2_000.0
    end

    test "treats nil views as zero in the average" do
      posts = [
        %CompetitorPost{views_count: 100},
        %CompetitorPost{views_count: nil}
      ]

      assert CompetitorResearch.rolling_avg_views(posts) == 50.0
    end
  end
end
