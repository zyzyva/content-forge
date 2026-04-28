defmodule ContentForge.Jobs.CompetitorScrapeRefresher do
  @moduledoc """
  Phase 17.6 cron entry. Re-scrapes every active product's
  competitor accounts on a weekly cadence so the corpus stays
  fresh for the corrective loop.

  Iterates products that have at least one active
  `CompetitorAccount` and enqueues one `CompetitorScraper` job
  per product. The scraper itself owns the viral-trigger logic
  (Phase 17.1): posts that cross the threshold since the last
  run get queued for `CompetitorCommentHarvester` automatically.

  Cadence: weekly via the Oban cron entry in `config/config.exs`.

  Note: the scraper does not currently filter the Apify actor's
  fetch by `since` date - de-duplication happens at the DB layer
  via the unique index on `(competitor_account_id, post_id)`
  added in 17.5. API-side incremental fetching is a future
  optimization; for now the existing scraper's full fetch +
  upsert keeps the corpus correct at moderate cost.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  import Ecto.Query, only: [from: 2]

  alias ContentForge.Jobs.CompetitorScraper
  alias ContentForge.Products.CompetitorAccount
  alias ContentForge.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case product_ids_with_active_competitors() do
      [] ->
        Logger.info("CompetitorScrapeRefresher: no products with active competitors; skipping")
        :ok

      ids ->
        Logger.info(
          "CompetitorScrapeRefresher: enqueueing CompetitorScraper for #{length(ids)} products"
        )

        Enum.each(ids, fn product_id ->
          %{"product_id" => product_id}
          |> CompetitorScraper.new(unique: [period: 60 * 60, fields: [:args, :worker]])
          |> Oban.insert()
        end)

        :ok
    end
  end

  @doc """
  Returns the list of product ids with at least one active
  competitor account. Public so tests + the operator surface
  share one definition.
  """
  @spec product_ids_with_active_competitors() :: [Ecto.UUID.t()]
  def product_ids_with_active_competitors do
    Repo.all(
      from(a in CompetitorAccount,
        where: a.active == true,
        select: a.product_id,
        distinct: true
      )
    )
  end
end
