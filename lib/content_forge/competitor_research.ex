defmodule ContentForge.CompetitorResearch do
  @moduledoc """
  Helpers shared by the competitor scrape + comment harvester
  pipelines (Phase 17).

  Owns the viral-post predicate so the threshold lives in one
  place. The scraper job calls `viral?/2` after computing the
  account's rolling engagement average; if `true` it enqueues
  `ContentForge.Jobs.CompetitorCommentHarvester` for that post.

  Thresholds are config-driven and can be tuned per-environment
  without code changes:

      config :content_forge, :competitor_research,
        viral_views_multiplier: 5,
        viral_views_floor: 100_000,
        max_comments_per_viral_post: 50

  Defaults match the v1 spec from `RESEARCH_LOOP_PLAN.md` Phase 1:
  a post crosses the threshold when its `views_count` is at
  least 5x the account's rolling average views OR clears the
  100k absolute floor.
  """

  alias ContentForge.Products.CompetitorPost

  @default_views_multiplier 5
  @default_views_floor 100_000
  @default_max_comments_per_viral_post 50

  @doc """
  Returns true when the post crosses the viral threshold.

  Either condition trips the predicate:

    * `views_count >= viral_views_floor` (default 100k), OR
    * `views_count >= rolling_avg_views * viral_views_multiplier`
      (default 5x), provided the rolling average is positive.

  Posts with `nil` or zero views never trip; the predicate is
  pure and does no DB work. Callers compute `rolling_avg_views`
  separately and pass it in.
  """
  @spec viral?(CompetitorPost.t() | map(), number()) :: boolean()
  def viral?(post, rolling_avg_views) when is_number(rolling_avg_views) do
    views = views_of(post)
    floor = viral_views_floor()
    multiplier = viral_views_multiplier()

    cond do
      views <= 0 -> false
      views >= floor -> true
      rolling_avg_views > 0 and views >= rolling_avg_views * multiplier -> true
      true -> false
    end
  end

  def viral?(_post, _avg), do: false

  @doc """
  Maximum comments harvested per viral post (top-N by like
  count). Surfaces the config value so the harvester reads
  through one accessor.
  """
  @spec max_comments_per_viral_post() :: pos_integer()
  def max_comments_per_viral_post do
    Keyword.get(config(), :max_comments_per_viral_post, @default_max_comments_per_viral_post)
  end

  @doc "Average views across the post list (zero when the list is empty)."
  @spec rolling_avg_views([CompetitorPost.t() | map()]) :: float()
  def rolling_avg_views([]), do: 0.0

  def rolling_avg_views(posts) when is_list(posts) do
    total = Enum.reduce(posts, 0, fn p, acc -> acc + views_of(p) end)
    total / length(posts)
  end

  # --- helpers --------------------------------------------------------------

  defp views_of(%CompetitorPost{views_count: n}) when is_integer(n), do: n
  defp views_of(%{views_count: n}) when is_integer(n), do: n
  defp views_of(%{"views_count" => n}) when is_integer(n), do: n
  defp views_of(_), do: 0

  defp viral_views_multiplier do
    Keyword.get(config(), :viral_views_multiplier, @default_views_multiplier)
  end

  defp viral_views_floor do
    Keyword.get(config(), :viral_views_floor, @default_views_floor)
  end

  defp config do
    Application.get_env(:content_forge, :competitor_research, [])
  end
end
