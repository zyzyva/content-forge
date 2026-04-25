defmodule ContentForge.CompetitorScraper.SqliteImporter do
  @moduledoc """
  Phase 17.5 backfill importer behind the
  `cf_import_twitter_sqlite` MCP tool.

  Reads a sqlite database produced by the standalone scraper in
  lead_intelligence (`tweets` + `comments` tables; see
  `~/projects/lead_intelligence/priv/twitter_scrapes.db` for
  the canonical shape) and upserts rows into
  `competitor_posts` and `competitor_post_comments` for the
  target competitor account. After the import completes the
  account's per-post `engagement_score` is recomputed against
  the broader corpus (`Products.recompute_engagement_scores_for_account/1`)
  so the score field reflects the full ingested set, not just
  the most recent scrape batch.

  Idempotency: a re-run over the same source produces zero new
  rows. Existing posts are reported as `posts_skipped`;
  existing comments are reported as `comments_skipped`. Tweets
  with no parent in the DB are silently skipped during the
  comment pass (the parent has to land first; if the source
  sqlite has orphan comments we ignore them).

  Optional `since` / `until` ISO date filters bound the import
  by `posted_at`. Format: `"YYYY-MM-DD"` or full ISO-8601
  datetime; both are accepted.
  """

  require Logger

  import Ecto.Query, only: [from: 2]

  alias ContentForge.Products
  alias ContentForge.Products.CompetitorAccount
  alias ContentForge.Products.CompetitorPost
  alias ContentForge.Products.CompetitorPostComment
  alias ContentForge.Repo

  @type opts :: %{
          required(:sqlite_path) => String.t(),
          required(:competitor) => CompetitorAccount.t(),
          optional(:since) => String.t() | nil,
          optional(:until) => String.t() | nil
        }

  @type result :: %{
          posts_imported: non_neg_integer(),
          posts_skipped: non_neg_integer(),
          comments_imported: non_neg_integer(),
          comments_skipped: non_neg_integer(),
          rolling_avg_engagement: float()
        }

  @spec import_twitter_sqlite(opts()) :: {:ok, result()} | {:error, term()}
  def import_twitter_sqlite(%{sqlite_path: path, competitor: %CompetitorAccount{} = account} = opts) do
    case File.exists?(path) do
      true -> open_and_import(path, account, opts)
      false -> {:error, :sqlite_not_found}
    end
  end

  defp open_and_import(path, account, opts) do
    case Exqlite.Sqlite3.open(path, mode: :readonly) do
      {:ok, conn} ->
        try do
          do_import(conn, account, opts)
        after
          Exqlite.Sqlite3.close(conn)
        end

      {:error, reason} ->
        {:error, {:sqlite_open_failed, reason}}
    end
  end

  defp do_import(conn, account, opts) do
    since_iso = normalize_iso(Map.get(opts, :since))
    until_iso = normalize_iso(Map.get(opts, :until))

    {posts_imported, posts_skipped} =
      conn
      |> stream_tweets(account.handle, since_iso, until_iso)
      |> Enum.reduce({0, 0}, fn row, {ins, skip} ->
        case upsert_post(account, row) do
          {:ok, %{status: :inserted}} -> {ins + 1, skip}
          {:ok, %{status: :skipped}} -> {ins, skip + 1}
          {:error, _} -> {ins, skip}
        end
      end)

    {comments_imported, comments_skipped} =
      conn
      |> stream_comments(account.handle)
      |> Enum.reduce({0, 0}, fn row, {ins, skip} ->
        case upsert_comment(account, row) do
          {:ok, %{status: :inserted}} -> {ins + 1, skip}
          {:ok, %{status: :skipped}} -> {ins, skip + 1}
          {:ignored, _} -> {ins, skip}
          {:error, _} -> {ins, skip}
        end
      end)

    {_updated, average} = Products.recompute_engagement_scores_for_account(account.id)

    {:ok,
     %{
       posts_imported: posts_imported,
       posts_skipped: posts_skipped,
       comments_imported: comments_imported,
       comments_skipped: comments_skipped,
       rolling_avg_engagement: average
     }}
  end

  # --- tweet streaming ------------------------------------------------------

  defp stream_tweets(conn, handle, since_iso, until_iso) do
    {sql, params} = build_tweets_query(handle, since_iso, until_iso)
    stream(conn, sql, params, &row_to_tweet_map/1)
  end

  # Filters by `posted_at` text. ISO-8601 date strings sort
  # lexicographically the same way they sort chronologically, so a
  # text comparison is correct without per-fixture unix timestamps.
  defp build_tweets_query(handle, since_iso, until_iso) do
    base = ~s|select platform_id, text, posted_at, posted_unix, likes, retweets, replies, views, conversation_id, url, raw_json from tweets where handle = ?|

    {clauses, params} =
      {[], []}
      |> maybe_add_clause(since_iso, "posted_at >= ?")
      |> maybe_add_clause(until_iso, "posted_at < ?")

    case clauses do
      [] -> {base, [handle]}
      _ -> {base <> " and " <> Enum.join(clauses, " and "), [handle | params]}
    end
  end

  defp maybe_add_clause({clauses, params}, nil, _sql), do: {clauses, params}
  defp maybe_add_clause({clauses, params}, value, sql), do: {clauses ++ [sql], params ++ [value]}

  defp row_to_tweet_map([
         platform_id,
         text,
         posted_at,
         _posted_unix,
         likes,
         retweets,
         replies,
         views,
         conversation_id,
         url,
         raw_json
       ]) do
    %{
      "platform_id" => platform_id,
      "text" => text,
      "posted_at" => posted_at,
      "likes" => likes,
      "retweets" => retweets,
      "replies" => replies,
      "views" => views,
      "conversation_id" => conversation_id,
      "url" => url,
      "raw_json" => raw_json
    }
  end

  defp upsert_post(%CompetitorAccount{} = account, row) do
    Products.upsert_competitor_post(%{
      competitor_account_id: account.id,
      post_id: to_string(row["platform_id"]),
      content: row["text"] || "",
      post_url: row["url"] || "",
      likes_count: row["likes"] || 0,
      comments_count: row["replies"] || 0,
      shares_count: row["retweets"] || 0,
      views_count: row["views"] || 0,
      conversation_id: row["conversation_id"],
      engagement_score: nil,
      posted_at: parse_datetime(row["posted_at"]),
      raw_data: decode_raw(row["raw_json"])
    })
  end

  defp decode_raw(nil), do: %{}

  defp decode_raw(json) when is_binary(json) do
    case JSON.decode(json) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp decode_raw(_), do: %{}

  # --- comment streaming ----------------------------------------------------

  defp stream_comments(conn, handle) do
    sql = ~s|select platform_id, parent_tweet_id, author_handle, text, posted_at, likes, replies, retweets, views, in_reply_to_id, conversation_id, raw_json from comments where parent_handle = ?|

    stream(conn, sql, [handle], &row_to_comment_map/1)
  end

  defp row_to_comment_map([
         platform_id,
         parent_tweet_id,
         author_handle,
         text,
         posted_at,
         likes,
         replies,
         retweets,
         views,
         in_reply_to_id,
         conversation_id,
         raw_json
       ]) do
    %{
      "platform_id" => platform_id,
      "parent_tweet_id" => parent_tweet_id,
      "author_handle" => author_handle,
      "text" => text,
      "posted_at" => posted_at,
      "likes" => likes,
      "replies" => replies,
      "retweets" => retweets,
      "views" => views,
      "in_reply_to_id" => in_reply_to_id,
      "conversation_id" => conversation_id,
      "raw_json" => raw_json
    }
  end

  defp upsert_comment(account, row) do
    case parent_post_id(account.id, row["parent_tweet_id"]) do
      nil ->
        {:ignored, :parent_not_imported}

      parent_id ->
        attrs = %{
          competitor_post_id: parent_id,
          platform_comment_id: to_string(row["platform_id"]),
          author_handle: row["author_handle"],
          text: row["text"] || "",
          posted_at: parse_datetime(row["posted_at"]),
          likes_count: row["likes"] || 0,
          replies_count: row["replies"] || 0,
          retweets_count: row["retweets"] || 0,
          views_count: row["views"] || 0,
          in_reply_to_id: row["in_reply_to_id"],
          conversation_id: row["conversation_id"],
          raw_payload: decode_raw(row["raw_json"])
        }

        case existing_comment?(parent_id, attrs.platform_comment_id) do
          true ->
            {:ok, %{status: :skipped}}

          false ->
            case Products.upsert_competitor_post_comment(attrs) do
              {:ok, _} -> {:ok, %{status: :inserted}}
              {:error, _} = err -> err
            end
        end
    end
  end

  defp parent_post_id(account_id, platform_id) do
    Repo.one(
      from(p in CompetitorPost,
        where:
          p.competitor_account_id == ^account_id and
            p.post_id == ^to_string(platform_id),
        select: p.id,
        limit: 1
      )
    )
  end

  defp existing_comment?(parent_id, platform_comment_id) do
    Repo.exists?(
      from(c in CompetitorPostComment,
        where:
          c.competitor_post_id == ^parent_id and
            c.platform_comment_id == ^platform_comment_id
      )
    )
  end

  # --- generic stream helper ------------------------------------------------

  defp stream(conn, sql, params, mapper) do
    {:ok, statement} = Exqlite.Sqlite3.prepare(conn, sql)
    :ok = Exqlite.Sqlite3.bind(statement, params)

    Stream.resource(
      fn -> statement end,
      fn stmt ->
        case Exqlite.Sqlite3.step(conn, stmt) do
          {:row, row} -> {[mapper.(row)], stmt}
          :done -> {:halt, stmt}
        end
      end,
      fn stmt -> Exqlite.Sqlite3.release(conn, stmt) end
    )
  end

  # --- date helpers ---------------------------------------------------------

  # Normalise a since/until input to the ISO string the SQL filter
  # compares against. Accepts plain dates ("2026-02-01") and full
  # ISO datetimes; anything unparseable becomes nil (no filter).
  defp normalize_iso(nil), do: nil
  defp normalize_iso(""), do: nil

  defp normalize_iso(value) when is_binary(value) do
    cond do
      match?({:ok, _, _}, DateTime.from_iso8601(value)) -> value
      match?({:ok, _}, Date.from_iso8601(value)) -> value
      true -> nil
    end
  end

  defp parse_datetime(nil), do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} ->
        dt

      _ ->
        case NaiveDateTime.from_iso8601(value) do
          {:ok, ndt} -> DateTime.from_naive!(ndt, "Etc/UTC")
          _ -> DateTime.utc_now() |> DateTime.truncate(:second)
        end
    end
  end

end
