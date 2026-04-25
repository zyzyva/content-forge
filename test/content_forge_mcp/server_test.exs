defmodule ContentForgeMCP.ServerTest do
  @moduledoc """
  Phase 17.3: per-tool happy-path + missing-dependency coverage
  for the Content Forge MCP server. Routes through the real
  context modules against the test DB; Oban-touching tools rely
  on `Oban.Testing` for assert_enqueued.
  """
  use ContentForge.DataCase, async: false
  use Oban.Testing, repo: ContentForge.Repo

  alias ContentForge.Jobs.CompetitorScraper
  alias ContentForge.Products
  alias ContentForge.Products.CompetitorIntel
  alias ContentForge.Repo
  alias ContentForgeMCP.Server

  defp call(name, args), do: Server.handle_tool_call(name, args)

  defp seed_product(attrs \\ %{}) do
    {:ok, product} =
      Products.create_product(Map.merge(%{name: "MCPLand", voice_profile: "warm"}, attrs))

    product
  end

  defp seed_competitor(product, attrs \\ %{}) do
    {:ok, account} =
      Products.create_competitor_account(
        Map.merge(
          %{
            product_id: product.id,
            platform: "twitter",
            handle: "rival",
            url: "https://x.com/rival",
            active: true
          },
          attrs
        )
      )

    account
  end

  defp seed_post(account, attrs \\ %{}) do
    {:ok, post} =
      Products.create_competitor_post(
        Map.merge(
          %{
            competitor_account_id: account.id,
            post_id: "p-#{System.unique_integer([:positive])}",
            content: "post body",
            posted_at: DateTime.utc_now() |> DateTime.truncate(:second),
            engagement_score: 1.0,
            views_count: 1_000
          },
          attrs
        )
      )

    post
  end

  describe "server_info/0 + tools/0" do
    test "advertises Content Forge as the server" do
      assert {"Content Forge", "1.0.0"} = Server.server_info()
    end

    test "registers exactly the nine documented tools" do
      names = Server.tools() |> Enum.map(& &1.name) |> MapSet.new()

      expected =
        MapSet.new(~w(
          cf_create_product
          cf_list_products
          cf_add_competitor
          cf_list_competitors
          cf_scrape_competitor
          cf_top_posts_for_synthesis
          cf_store_intel
          cf_get_intel
          cf_import_twitter_sqlite
        ))

      assert names == expected
    end

    test "unknown tool name returns a structured not_found envelope" do
      assert {:error, %{code: "not_found", message: msg}} =
               call("definitely_not_a_tool", %{})

      assert msg =~ "Unknown tool"
    end
  end

  describe "cf_create_product" do
    test "creates a product with the supplied name" do
      assert {:ok, %{product_id: id, name: "AcmeCorp"}} =
               call("cf_create_product", %{"name" => "AcmeCorp"})

      assert is_binary(id)
      assert %{name: "AcmeCorp"} = Products.get_product(id)
    end

    test "returns validation_failed when name is missing" do
      assert {:error, %{code: "validation_failed", details: %{field: "name"}}} =
               call("cf_create_product", %{})
    end

    test "publishing_targets must be a JSON-encoded object" do
      assert {:error, %{code: "validation_failed", details: %{field: "publishing_targets"}}} =
               call("cf_create_product", %{
                 "name" => "JsonLand",
                 "publishing_targets" => "not-json"
               })
    end

    test "honors voice_profile + JSON publishing_targets" do
      assert {:ok, %{product_id: id}} =
               call("cf_create_product", %{
                 "name" => "FullLand",
                 "voice_profile" => "professional",
                 "publishing_targets" => ~s({"twitter":"@full"})
               })

      product = Products.get_product(id)
      assert product.voice_profile == "professional"
      assert product.publishing_targets == %{"twitter" => "@full"}
    end
  end

  describe "cf_list_products" do
    test "returns each product with competitor count and latest_intel_at" do
      product = seed_product()
      _other = seed_product(%{name: "OtherLand"})
      _account = seed_competitor(product)

      {:ok, _intel} =
        Products.create_competitor_intel(%{
          product_id: product.id,
          summary: "intel",
          trending_topics: [],
          winning_formats: [],
          effective_hooks: [],
          source_count: 1
        })

      assert {:ok, rows} = call("cf_list_products", %{})

      mcp_land = Enum.find(rows, &(&1.product_id == product.id))
      assert mcp_land.name == "MCPLand"
      assert mcp_land.competitor_count == 1
      assert is_binary(mcp_land.latest_intel_at)
    end
  end

  describe "cf_add_competitor" do
    test "registers a competitor for an existing product" do
      product = seed_product()

      assert {:ok, %{competitor_id: id, platform: "linkedin", handle: "rivalcorp"}} =
               call("cf_add_competitor", %{
                 "product_id" => product.id,
                 "platform" => "linkedin",
                 "handle" => "rivalcorp"
               })

      assert is_binary(id)
    end

    test "rejects an unknown platform" do
      product = seed_product()

      assert {:error, %{code: "validation_failed", details: %{field: "platform"}}} =
               call("cf_add_competitor", %{
                 "product_id" => product.id,
                 "platform" => "tiktok",
                 "handle" => "rival"
               })
    end

    test "returns not_found when product does not exist" do
      assert {:error, %{code: "not_found"}} =
               call("cf_add_competitor", %{
                 "product_id" => Ecto.UUID.generate(),
                 "platform" => "twitter",
                 "handle" => "rival"
               })
    end

    test "returns not_found on a malformed product id" do
      assert {:error, %{code: "not_found"}} =
               call("cf_add_competitor", %{
                 "product_id" => "not-a-uuid",
                 "platform" => "twitter",
                 "handle" => "rival"
               })
    end
  end

  describe "cf_list_competitors" do
    test "lists competitors with post_count and last_scraped_at" do
      product = seed_product()
      account = seed_competitor(product)

      seed_post(account, %{posted_at: DateTime.utc_now() |> DateTime.truncate(:second)})
      seed_post(account)

      assert {:ok, rows} = call("cf_list_competitors", %{"product_id" => product.id})
      assert [row] = rows
      assert row.competitor_id == account.id
      assert row.platform == "twitter"
      assert row.handle == "rival"
      assert row.post_count == 2
      assert is_binary(row.last_scraped_at)
    end

    test "empty list when no competitors registered yet" do
      product = seed_product()
      assert {:ok, []} = call("cf_list_competitors", %{"product_id" => product.id})
    end

    test "not_found on unknown product" do
      assert {:error, %{code: "not_found"}} =
               call("cf_list_competitors", %{"product_id" => Ecto.UUID.generate()})
    end
  end

  describe "cf_scrape_competitor" do
    test "enqueues CompetitorScraper for the product owning the competitor" do
      product = seed_product()
      account = seed_competitor(product)

      assert {:ok, %{job_id: job_id, status: "enqueued"}} =
               call("cf_scrape_competitor", %{"competitor_id" => account.id})

      assert is_integer(job_id)

      assert_enqueued(
        worker: CompetitorScraper,
        args: %{"product_id" => product.id}
      )
    end

    test "not_found on unknown competitor" do
      assert {:error, %{code: "not_found"}} =
               call("cf_scrape_competitor", %{"competitor_id" => Ecto.UUID.generate()})
    end

    test "not_found on malformed competitor id" do
      assert {:error, %{code: "not_found"}} =
               call("cf_scrape_competitor", %{"competitor_id" => "not-a-uuid"})
    end
  end

  describe "cf_top_posts_for_synthesis" do
    test "returns posts ordered by engagement_score desc with comments preloaded" do
      product = seed_product()
      account = seed_competitor(product)

      lo = seed_post(account, %{engagement_score: 0.5})
      hi = seed_post(account, %{engagement_score: 5.0, conversation_id: "conv-hi"})

      {:ok, _} =
        Products.upsert_competitor_post_comment(%{
          competitor_post_id: hi.id,
          platform_comment_id: "c1",
          author_handle: "fan",
          text: "wow",
          likes_count: 9,
          posted_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      assert {:ok, %{posts: [first, second]}} =
               call("cf_top_posts_for_synthesis", %{"product_id" => product.id, "n" => 5})

      assert first.competitor_post_id == hi.id
      assert second.competitor_post_id == lo.id

      assert [comment] = first.comments
      assert comment.platform_comment_id == "c1"
      assert comment.text == "wow"
      assert is_binary(first.posted_at)
    end

    test "rejects unknown window value" do
      product = seed_product()

      assert {:error, %{code: "validation_failed", details: %{field: "window"}}} =
               call("cf_top_posts_for_synthesis", %{
                 "product_id" => product.id,
                 "window" => "decade"
               })
    end

    test "rejects non-positive n" do
      product = seed_product()

      assert {:error, %{code: "validation_failed", details: %{field: "n"}}} =
               call("cf_top_posts_for_synthesis", %{"product_id" => product.id, "n" => 0})
    end

    test "filters posts to the requested window" do
      product = seed_product()
      account = seed_competitor(product)

      old =
        DateTime.utc_now()
        |> DateTime.add(-365 * 24 * 3600, :second)
        |> DateTime.truncate(:second)

      _ancient = seed_post(account, %{posted_at: old, engagement_score: 99.0})
      recent = seed_post(account, %{engagement_score: 1.0})

      assert {:ok, %{posts: posts}} =
               call("cf_top_posts_for_synthesis", %{
                 "product_id" => product.id,
                 "window" => "week"
               })

      assert [%{competitor_post_id: id}] = posts
      assert id == recent.id
    end
  end

  describe "cf_store_intel" do
    test "persists a competitor_intel row with audience_signals + window" do
      product = seed_product()

      payload = %{
        "product_id" => product.id,
        "summary" => "rivals are leaning on case studies",
        "trending_topics" => ["case studies", "behind the scenes"],
        "winning_formats" => ["carousels"],
        "effective_hooks" => ["before / after"],
        "audience_signals" => ["asking about pricing", "skeptical of guarantees"],
        "source_count" => 7,
        "window" => "week"
      }

      assert {:ok, %{intel_id: id, product_id: pid, created_at: created_at}} =
               call("cf_store_intel", payload)

      assert pid == product.id
      assert is_binary(created_at)

      row = Repo.get!(CompetitorIntel, id)
      assert row.window == "week"
      assert row.audience_signals == ["asking about pricing", "skeptical of guarantees"]
      assert row.source_count == 7
    end

    test "accepts JSON-encoded list strings for the array params" do
      product = seed_product()

      assert {:ok, _} =
               call("cf_store_intel", %{
                 "product_id" => product.id,
                 "summary" => "json shape",
                 "trending_topics" => ~s(["a","b"]),
                 "winning_formats" => ~s(["x"]),
                 "effective_hooks" => ~s(["y"]),
                 "audience_signals" => ~s([]),
                 "source_count" => 0
               })
    end

    test "rejects non-list trending_topics" do
      product = seed_product()

      assert {:error, %{code: "validation_failed", details: %{field: "trending_topics"}}} =
               call("cf_store_intel", %{
                 "product_id" => product.id,
                 "summary" => "x",
                 "trending_topics" => "not-a-list",
                 "winning_formats" => [],
                 "effective_hooks" => [],
                 "audience_signals" => [],
                 "source_count" => 0
               })
    end

    test "rejects an unknown window value" do
      product = seed_product()

      assert {:error, %{code: "validation_failed", details: %{field: "window"}}} =
               call("cf_store_intel", %{
                 "product_id" => product.id,
                 "summary" => "x",
                 "trending_topics" => [],
                 "winning_formats" => [],
                 "effective_hooks" => [],
                 "audience_signals" => [],
                 "source_count" => 0,
                 "window" => "decade"
               })
    end
  end

  describe "cf_get_intel" do
    test "latest=true returns the newest intel row" do
      product = seed_product()

      {:ok, old} =
        Products.create_competitor_intel(%{
          product_id: product.id,
          summary: "old",
          trending_topics: [],
          winning_formats: [],
          effective_hooks: [],
          source_count: 1
        })

      # Back-date the older row so the desc:inserted_at ordering
      # does not depend on second-precision ties between two
      # near-simultaneous inserts.
      old
      |> Ecto.Changeset.change(inserted_at: DateTime.add(old.inserted_at, -60, :second))
      |> Repo.update!()

      {:ok, _new} =
        Products.create_competitor_intel(%{
          product_id: product.id,
          summary: "newest",
          trending_topics: ["foo"],
          winning_formats: [],
          effective_hooks: [],
          audience_signals: ["sig"],
          source_count: 2,
          window: "week"
        })

      assert {:ok, intel} = call("cf_get_intel", %{"product_id" => product.id})
      assert intel.summary == "newest"
      assert intel.audience_signals == ["sig"]
      assert intel.window == "week"
    end

    test "latest=false returns up to five rows" do
      product = seed_product()

      for i <- 1..7 do
        {:ok, _} =
          Products.create_competitor_intel(%{
            product_id: product.id,
            summary: "row #{i}",
            trending_topics: [],
            winning_formats: [],
            effective_hooks: [],
            source_count: i
          })
      end

      assert {:ok, rows} =
               call("cf_get_intel", %{"product_id" => product.id, "latest" => false})

      assert length(rows) == 5
    end

    test "not_found when no intel exists yet" do
      product = seed_product()

      assert {:error, %{code: "not_found"}} =
               call("cf_get_intel", %{"product_id" => product.id})
    end
  end

  describe "cf_import_twitter_sqlite" do
    test "registered but returns not_implemented until Phase 17.5 ships" do
      assert {:error, %{code: "not_implemented", details: %{phase: "17.5"}}} =
               call("cf_import_twitter_sqlite", %{
                 "sqlite_path" => "/tmp/scraper.db",
                 "competitor_id" => Ecto.UUID.generate()
               })
    end
  end
end
