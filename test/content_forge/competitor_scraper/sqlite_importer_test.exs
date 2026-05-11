defmodule ContentForge.CompetitorScraper.SqliteImporterTest do
  @moduledoc """
  Phase 17.5: backfill importer behind cf_import_twitter_sqlite.

  Builds a fixture sqlite database in test setup with the same
  shape as the standalone scraper's `priv/twitter_scrapes.db`
  (tweets + comments tables) so we never depend on the real
  6,800-row file. Asserts:

    * Happy import populates competitor_posts + comments + the
      counts returned match.
    * Re-running over the same source produces zero new rows.
    * since/until ISO date filters bound the import.
    * Account engagement_score gets recomputed after backfill.
    * Comments without a parent tweet are silently skipped.
  """
  use ContentForge.DataCase, async: false

  alias ContentForge.CompetitorScraper.SqliteImporter
  alias ContentForge.Products
  alias ContentForge.Products.CompetitorPost
  alias ContentForge.Products.CompetitorPostComment
  alias ContentForge.Repo

  @handle "cleanwithmike"

  setup do
    {:ok, product} =
      Products.create_product(%{name: "CleanLand", voice_profile: "warm"})

    {:ok, competitor} =
      Products.create_competitor_account(%{
        product_id: product.id,
        platform: "twitter",
        handle: @handle,
        url: "https://x.com/#{@handle}",
        active: true
      })

    sqlite_path =
      Path.join(System.tmp_dir!(), "cf_import_test_#{System.unique_integer([:positive])}.db")

    seed_fixture_sqlite!(sqlite_path)

    on_exit(fn ->
      File.rm(sqlite_path)
    end)

    %{product: product, competitor: competitor, sqlite_path: sqlite_path}
  end

  defp seed_fixture_sqlite!(path) do
    {:ok, conn} = Exqlite.Sqlite3.open(path)

    :ok =
      Exqlite.Sqlite3.execute(conn, """
      CREATE TABLE tweets (
        platform_id TEXT PRIMARY KEY,
        handle TEXT NOT NULL,
        text TEXT,
        posted_at TEXT,
        posted_unix INTEGER,
        likes INTEGER DEFAULT 0,
        retweets INTEGER DEFAULT 0,
        replies INTEGER DEFAULT 0,
        quotes INTEGER DEFAULT 0,
        views INTEGER DEFAULT 0,
        bookmarks INTEGER DEFAULT 0,
        is_reply INTEGER DEFAULT 0,
        in_reply_to_username TEXT,
        conversation_id TEXT,
        is_pinned INTEGER DEFAULT 0,
        url TEXT,
        raw_json TEXT,
        scraped_at TEXT
      );
      """)

    :ok =
      Exqlite.Sqlite3.execute(conn, """
      CREATE TABLE comments (
        platform_id TEXT PRIMARY KEY,
        parent_tweet_id TEXT NOT NULL,
        parent_handle TEXT NOT NULL,
        author_handle TEXT,
        text TEXT,
        posted_at TEXT,
        posted_unix INTEGER,
        likes INTEGER DEFAULT 0,
        retweets INTEGER DEFAULT 0,
        replies INTEGER DEFAULT 0,
        views INTEGER DEFAULT 0,
        bookmarks INTEGER DEFAULT 0,
        in_reply_to_id TEXT,
        in_reply_to_username TEXT,
        conversation_id TEXT,
        url TEXT,
        raw_json TEXT,
        scraped_at TEXT
      );
      """)

    insert_tweet = fn args ->
      [post_id, posted_at, posted_unix, likes, replies, retweets, views, conv_id] = args

      sql =
        ~s|INSERT INTO tweets (platform_id, handle, text, posted_at, posted_unix, likes, retweets, replies, views, conversation_id, url, raw_json) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)|

      {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)

      :ok =
        Exqlite.Sqlite3.bind(stmt, [
          post_id,
          @handle,
          "tweet body #{post_id}",
          posted_at,
          posted_unix,
          likes,
          retweets,
          replies,
          views,
          conv_id,
          "https://x.com/#{@handle}/status/#{post_id}",
          ~s({"id":"#{post_id}"})
        ])

      :done = Exqlite.Sqlite3.step(conn, stmt)
      Exqlite.Sqlite3.release(conn, stmt)
    end

    insert_comment = fn args ->
      [comment_id, parent_id, author, posted_at, likes] = args

      sql =
        ~s|INSERT INTO comments (platform_id, parent_tweet_id, parent_handle, author_handle, text, posted_at, likes, conversation_id, raw_json) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)|

      {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)

      :ok =
        Exqlite.Sqlite3.bind(stmt, [
          comment_id,
          parent_id,
          @handle,
          author,
          "comment body #{comment_id}",
          posted_at,
          likes,
          parent_id,
          ~s({"id":"#{comment_id}"})
        ])

      :done = Exqlite.Sqlite3.step(conn, stmt)
      Exqlite.Sqlite3.release(conn, stmt)
    end

    # Three tweets across two months.
    insert_tweet.(["t-jan", "2026-01-15T10:00:00Z", 1_736_938_800, 100, 5, 10, 1_000, "conv-jan"])
    insert_tweet.(["t-feb", "2026-02-15T10:00:00Z", 1_739_617_200, 200, 8, 20, 5_000, "conv-feb"])
    insert_tweet.(["t-mar", "2026-03-15T10:00:00Z", 1_742_036_400, 50, 2, 5, 250, "conv-mar"])

    # Two comments on the Feb tweet, one orphan with no parent in tweets.
    insert_comment.(["c-1", "t-feb", "fan42", "2026-02-16T11:00:00Z", 9])
    insert_comment.(["c-2", "t-feb", "skeptic", "2026-02-16T12:00:00Z", 3])
    insert_comment.(["c-orphan", "t-missing", "ghost", "2026-02-17T10:00:00Z", 1])

    :ok = Exqlite.Sqlite3.close(conn)
  end

  describe "happy path" do
    test "imports tweets + comments and returns the counts", %{
      competitor: competitor,
      sqlite_path: path
    } do
      assert {:ok, result} =
               SqliteImporter.import_twitter_sqlite(%{
                 sqlite_path: path,
                 competitor: competitor
               })

      assert result.posts_imported == 3
      assert result.posts_skipped == 0
      assert result.comments_imported == 2
      assert result.comments_skipped == 0
      assert result.rolling_avg_engagement > 0

      assert Repo.aggregate(CompetitorPost, :count, :id) == 3
      assert Repo.aggregate(CompetitorPostComment, :count, :id) == 2

      [feb] = Repo.all(from(p in CompetitorPost, where: p.post_id == "t-feb"))
      assert feb.likes_count == 200
      assert feb.comments_count == 8
      assert feb.shares_count == 20
      assert feb.views_count == 5_000
      assert feb.conversation_id == "conv-feb"
      assert feb.engagement_score > 0
      assert feb.posted_at == ~U[2026-02-15 10:00:00Z]
    end

    test "comments link to the right parent post", %{competitor: competitor, sqlite_path: path} do
      {:ok, _} =
        SqliteImporter.import_twitter_sqlite(%{
          sqlite_path: path,
          competitor: competitor
        })

      [feb] = Repo.all(from(p in CompetitorPost, where: p.post_id == "t-feb"))
      comments = Products.list_comments_for_post(feb.id)
      assert length(comments) == 2
      assert Enum.map(comments, & &1.platform_comment_id) |> Enum.sort() == ["c-1", "c-2"]
    end

    test "engagement_score is recomputed against the corpus average",
         %{competitor: competitor, sqlite_path: path} do
      {:ok, result} =
        SqliteImporter.import_twitter_sqlite(%{
          sqlite_path: path,
          competitor: competitor
        })

      avg = result.rolling_avg_engagement

      posts =
        Repo.all(from(p in CompetitorPost, where: p.competitor_account_id == ^competitor.id))
        |> Map.new(&{&1.post_id, &1})

      # likes + replies*2 + retweets*3
      assert_in_delta posts["t-jan"].engagement_score, (100 + 5 * 2 + 10 * 3) / avg, 0.0001
      assert_in_delta posts["t-feb"].engagement_score, (200 + 8 * 2 + 20 * 3) / avg, 0.0001
      assert_in_delta posts["t-mar"].engagement_score, (50 + 2 * 2 + 5 * 3) / avg, 0.0001
    end
  end

  describe "idempotency" do
    test "re-running over the same source inserts zero new rows",
         %{competitor: competitor, sqlite_path: path} do
      {:ok, first} =
        SqliteImporter.import_twitter_sqlite(%{
          sqlite_path: path,
          competitor: competitor
        })

      assert first.posts_imported == 3
      assert first.comments_imported == 2

      {:ok, second} =
        SqliteImporter.import_twitter_sqlite(%{
          sqlite_path: path,
          competitor: competitor
        })

      assert second.posts_imported == 0
      assert second.posts_skipped == 3
      assert second.comments_imported == 0
      assert second.comments_skipped == 2

      assert Repo.aggregate(CompetitorPost, :count, :id) == 3
      assert Repo.aggregate(CompetitorPostComment, :count, :id) == 2
    end
  end

  describe "since/until filters" do
    test "since=2026-02-01 excludes the January tweet",
         %{competitor: competitor, sqlite_path: path} do
      {:ok, result} =
        SqliteImporter.import_twitter_sqlite(%{
          sqlite_path: path,
          competitor: competitor,
          since: "2026-02-01"
        })

      assert result.posts_imported == 2
      post_ids = Repo.all(from(p in CompetitorPost, select: p.post_id))
      assert "t-jan" not in post_ids
      assert "t-feb" in post_ids
      assert "t-mar" in post_ids
    end

    test "until=2026-03-01 excludes the March tweet",
         %{competitor: competitor, sqlite_path: path} do
      {:ok, result} =
        SqliteImporter.import_twitter_sqlite(%{
          sqlite_path: path,
          competitor: competitor,
          until: "2026-03-01"
        })

      assert result.posts_imported == 2
      post_ids = Repo.all(from(p in CompetitorPost, select: p.post_id))
      assert "t-jan" in post_ids
      assert "t-feb" in post_ids
      assert "t-mar" not in post_ids
    end

    test "since + until together yield only the Feb tweet",
         %{competitor: competitor, sqlite_path: path} do
      {:ok, result} =
        SqliteImporter.import_twitter_sqlite(%{
          sqlite_path: path,
          competitor: competitor,
          since: "2026-02-01",
          until: "2026-03-01"
        })

      assert result.posts_imported == 1
      assert [%{post_id: "t-feb"}] = Repo.all(CompetitorPost)
    end
  end

  describe "missing source" do
    test "non-existent sqlite returns :sqlite_not_found",
         %{competitor: competitor} do
      assert {:error, :sqlite_not_found} =
               SqliteImporter.import_twitter_sqlite(%{
                 sqlite_path: "/tmp/definitely_not_here_#{System.unique_integer()}.db",
                 competitor: competitor
               })
    end
  end

  describe "orphan comments" do
    test "comments without a parent tweet in the corpus are silently skipped",
         %{competitor: competitor, sqlite_path: path} do
      {:ok, result} =
        SqliteImporter.import_twitter_sqlite(%{
          sqlite_path: path,
          competitor: competitor
        })

      # The fixture has 3 comments total; the orphan (c-orphan) points
      # at parent t-missing which is not in the tweets table.
      assert result.comments_imported == 2
      assert Repo.aggregate(CompetitorPostComment, :count, :id) == 2

      orphan =
        Repo.one(from(c in CompetitorPostComment, where: c.platform_comment_id == "c-orphan"))

      assert orphan == nil
    end
  end
end
