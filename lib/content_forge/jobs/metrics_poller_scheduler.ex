defmodule ContentForge.Jobs.MetricsPollerScheduler do
  @moduledoc """
  Phase 17.6 cron entry. Iterates active products and enqueues
  one `MetricsPoller` job per product so the corrective loop
  has fresh scoreboard data to consult.

  "Active product" v1 = a product with at least one
  `PublishedPost` whose `posted_at` is within the last 90 days.
  Products that have not published recently are skipped to keep
  the cron's pricing footprint bounded.

  Cadence: every 6 hours via the Oban cron entry in
  `config/config.exs`. The MetricsPoller worker itself owns the
  per-post measurement cadence; this scheduler just ensures
  every active product gets a poll attempt at a regular tick.

  Fail-safe: if no active products exist, the job logs and
  returns `:ok` without enqueueing anything.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  import Ecto.Query, only: [from: 2]

  alias ContentForge.Jobs.MetricsPoller
  alias ContentForge.Publishing.PublishedPost
  alias ContentForge.Repo

  @active_window_days 90

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case active_product_ids() do
      [] ->
        Logger.info(
          "MetricsPollerScheduler: no active products in last #{@active_window_days}d; skipping"
        )

        :ok

      ids ->
        Logger.info(
          "MetricsPollerScheduler: enqueueing MetricsPoller for #{length(ids)} active products"
        )

        Enum.each(ids, fn product_id ->
          %{"product_id" => product_id}
          |> MetricsPoller.new(unique: [period: 60 * 60, fields: [:args, :worker]])
          |> Oban.insert()
        end)

        :ok
    end
  end

  @doc """
  Returns the list of product ids with at least one
  `PublishedPost` posted within the active window. Public so
  tests + the operator surface (cf_recent_scoreboard) can share
  the same definition.
  """
  @spec active_product_ids() :: [Ecto.UUID.t()]
  def active_product_ids do
    cutoff =
      DateTime.utc_now()
      |> DateTime.add(-@active_window_days * 24 * 3600, :second)

    Repo.all(
      from(p in PublishedPost,
        where: not is_nil(p.posted_at) and p.posted_at >= ^cutoff,
        select: p.product_id,
        distinct: true
      )
    )
  end
end
