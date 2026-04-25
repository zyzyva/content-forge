defmodule ContentForge.Jobs.CompetitorCommentHarvester do
  @moduledoc """
  Oban worker that pulls the top-N comments on a viral competitor
  post and upserts them into `competitor_post_comments`.

  Triggered by:

    * `ContentForge.Jobs.CompetitorScraper` on initial post ingest
      when a post crosses the viral threshold defined in
      `ContentForge.CompetitorResearch.viral?/2`.
    * The competitor refresher cron (Phase 17.6) for posts whose
      view count crosses since the last run.

  ## Args

      %{ "competitor_post_id" => binary_id }

  Optionally accepts `"limit"` (positive integer) to override
  the default `CompetitorResearch.max_comments_per_viral_post/0`.

  ## Failure modes

    * Missing post id or unknown post id -> `{:cancel, reason}`.
      Re-running with a stale id never errors loudly.
    * Adapter `:not_configured` -> `{:cancel, :scraper_adapter_not_configured}`
      so the job clears and operators see the misconfiguration in logs.
    * Adapter `:missing_conversation_id` -> `{:cancel, ...}`. The
      post has no thread to harvest.
    * Adapter `{:error, {:transient, ...}}` -> `{:error, _}` so Oban
      retries on its backoff schedule.
    * Per-comment changeset failures log + skip; the job still
      returns `:ok` if any comments persist (best-effort batch).
  """
  use Oban.Worker, queue: :competitor, max_attempts: 3

  require Logger

  alias ContentForge.Products
  alias ContentForge.Products.CompetitorAccount
  alias ContentForge.Products.CompetitorPost
  alias ContentForge.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"competitor_post_id" => post_id} = args}) when is_binary(post_id) do
    case load_post(post_id) do
      nil ->
        Logger.warning("CompetitorCommentHarvester: post #{post_id} not found, cancelling")
        {:cancel, :post_not_found}

      %CompetitorPost{} = post ->
        run_harvest(post, fetch_limit(args), scraper_adapter())
    end
  end

  def perform(%Oban.Job{}), do: {:cancel, :missing_competitor_post_id}

  # --- harvest --------------------------------------------------------------

  defp run_harvest(_post, _limit, nil) do
    {:cancel, :scraper_adapter_not_configured}
  end

  defp run_harvest(%CompetitorPost{} = post, limit, adapter) do
    opts = [limit: limit, platform: platform_of(post)]

    case adapter.fetch_comments(post, opts) do
      {:ok, comments} ->
        upsert_all(comments)
        :ok

      {:error, :not_configured} ->
        {:cancel, :scraper_adapter_not_configured}

      {:error, :missing_conversation_id} ->
        Logger.warning(
          "CompetitorCommentHarvester: post #{post.id} has no conversation_id; skipping"
        )

        {:cancel, :missing_conversation_id}

      {:error, {:transient, _, _} = reason} ->
        {:error, reason}

      {:error, reason} ->
        Logger.error(
          "CompetitorCommentHarvester: harvest for post #{post.id} failed: #{inspect(reason)}"
        )

        {:cancel, reason}
    end
  end

  defp upsert_all(comments) do
    Enum.each(comments, fn attrs ->
      case Products.upsert_competitor_post_comment(attrs) do
        {:ok, _row} ->
          :ok

        {:error, changeset} ->
          Logger.warning(
            "CompetitorCommentHarvester: skipped comment #{inspect(attrs[:platform_comment_id])} - #{inspect(changeset.errors)}"
          )
      end
    end)
  end

  # --- helpers --------------------------------------------------------------

  defp load_post(post_id) do
    case Repo.get(CompetitorPost, post_id) do
      nil -> nil
      post -> Repo.preload(post, :competitor_account)
    end
  rescue
    Ecto.Query.CastError -> nil
  end

  defp platform_of(%CompetitorPost{competitor_account: %CompetitorAccount{platform: p}})
       when is_binary(p),
       do: p

  defp platform_of(_), do: nil

  defp fetch_limit(%{"limit" => n}) when is_integer(n) and n > 0, do: n
  defp fetch_limit(_), do: nil

  defp scraper_adapter, do: Application.get_env(:content_forge, :scraper_adapter)
end
