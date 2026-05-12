defmodule ContentForgeMCP.Server do
  @moduledoc """
  Content Forge MCP server (Phase 17.3).

  Exposes the research-loop operations that a Claude Code session
  needs to walk the corpus-of-record loop end-to-end without
  touching the LiveView dashboard. Every tool is product-scoped
  and routes through the existing context modules
  (`ContentForge.Products`, `ContentForge.Jobs.*`) so behavior
  stays consistent with the dashboard surface.

  ## Tool catalogue

    * `cf_create_product` - mint a product
    * `cf_list_products` - product index with competitor + intel counts
    * `cf_add_competitor` - register a competitor account on a product
    * `cf_list_competitors` - per-product competitor index with
      post counts + last_scraped_at
    * `cf_scrape_competitor` - enqueue an Oban scrape for the
      product owning the competitor (returns acknowledgement)
    * `cf_top_posts_for_synthesis` - top N posts by engagement
      score within a window, with their captured comments
    * `cf_store_intel` - persist a manually-synthesized
      `competitor_intel` row (used by the without-key MCP
      completion path from Phase 17.4)
    * `cf_get_intel` - latest competitor intel for a product, or
      the last five rows when `latest: false`
    * `cf_list_pending_syntheses` - list of without-key
      synthesis requests waiting for manual completion via the
      MCP route (Phase 17.4)
    * `cf_import_twitter_sqlite` - backfill a competitor's posts
      and comments from the standalone scraper's sqlite (Phase
      17.5)
    * `cf_recent_scoreboard` - operator surface added in 17.6.
      Returns recent winners + losers per product plus an
      indication of whether the corrective trigger fired. Used
      to verify the corrective loop is closing without trawling
      the DB
    * `cf_publish_text` - publish a text post to one or more platforms
    * `cf_publish_video` - publish a completed VideoJob to platforms
    * `cf_platform_status` - check OAuth connection status per platform
    * `cf_list_published_posts` - list published posts for a product

  ## Error envelope

  Every tool returns either `{:ok, success_map}` on the happy
  path or `{:error, %{code: code, message: message, details:
  details}}` on failure. The stdio transport in
  `ContentForgeMCP.StdioServer` JSON-encodes the error envelope
  into the text content slot so a Claude session can parse it.

  Standard codes: `not_found`, `unauthorized`, `not_configured`,
  `validation_failed`, `dependency_error`, `not_implemented`.
  """

  use SimpleMCP

  require Logger

  import Ecto.Query, only: [from: 2]

  alias ContentForge.CompetitorScraper.SqliteImporter
  alias ContentForge.ContentGeneration
  alias ContentForge.Jobs.CompetitorScraper
  alias ContentForge.Jobs.MetricsPollerScheduler
  alias ContentForge.Metrics.ScoreboardEntry
  alias ContentForge.OpenClawTools.Authorization
  alias ContentForge.OpenClawTools.Confirmation
  alias ContentForge.Products
  alias ContentForge.Products.CompetitorAccount
  alias ContentForge.Products.CompetitorIntel
  alias ContentForge.Products.CompetitorPost
  alias ContentForge.Products.PendingIntelSynthesis
  alias ContentForge.Products.Product
  alias ContentForge.Publishing
  alias ContentForge.Publishing.VideoJob
  alias ContentForge.Repo

  @platforms ~w(twitter linkedin reddit facebook instagram youtube)
  @windows ~w(all week month)
  @top_posts_default 10
  @top_posts_max 50

  @impl true
  def server_info, do: {"Content Forge", "1.0.0"}

  # --- tool catalogue -------------------------------------------------------

  @impl true
  def tools do
    [
      SimpleMCP.Tool.new(
        "cf_create_product",
        "Create a new Content Forge product (the unit every other tool scopes to).",
        %{
          name: {:required, :string, description: "Product name."},
          voice_profile: {:optional, :string, description: "Optional voice profile descriptor."},
          publishing_targets:
            {:optional, :string,
             description:
               "Optional JSON-encoded map of publishing targets (per-platform handles, etc)."}
        }
      ),
      SimpleMCP.Tool.new(
        "cf_list_products",
        "List every product with competitor count and latest intel timestamp.",
        %{}
      ),
      SimpleMCP.Tool.new(
        "cf_add_competitor",
        "Register a competitor account on a product.",
        %{
          product_id: {:required, :string, description: "Product UUID."},
          platform:
            {:required, :string,
             description: "One of: twitter, linkedin, reddit, facebook, instagram, youtube."},
          handle: {:required, :string, description: "Account handle (no leading @)."}
        }
      ),
      SimpleMCP.Tool.new(
        "cf_list_competitors",
        "List competitors for a product with per-account post counts and last_scraped_at.",
        %{
          product_id: {:required, :string, description: "Product UUID."}
        }
      ),
      SimpleMCP.Tool.new(
        "cf_scrape_competitor",
        "Enqueue a CompetitorScraper Oban job for the product owning this competitor. Async; results land in competitor_posts asynchronously.",
        %{
          competitor_id: {:required, :string, description: "Competitor account UUID."}
        }
      ),
      SimpleMCP.Tool.new(
        "cf_top_posts_for_synthesis",
        "Top N competitor posts for a product, scored against their account average within the chosen window. Each post carries its captured comments (top by likes).",
        %{
          product_id: {:required, :string, description: "Product UUID."},
          n: {:optional, :integer, description: "Max posts to return (default 10, max 50)."},
          window: {:optional, :string, description: "Time window: all (default), week, or month."}
        }
      ),
      SimpleMCP.Tool.new(
        "cf_store_intel",
        "Persist a synthesized competitor_intel row. Used by the without-key MCP completion path; the autonomous synthesizer uses the same shape.",
        %{
          product_id: {:required, :string, description: "Product UUID."},
          summary: {:required, :string, description: "Plain-English synthesis (2-4 sentences)."},
          trending_topics: {:required, :string, description: "JSON-encoded list of strings."},
          winning_formats: {:required, :string, description: "JSON-encoded list of strings."},
          effective_hooks: {:required, :string, description: "JSON-encoded list of strings."},
          audience_signals:
            {:required, :string,
             description:
               "JSON-encoded list of audience-signal strings. Pass an empty list when no comments fed the synthesis."},
          source_count:
            {:required, :integer, description: "How many source posts seeded the synthesis."},
          window:
            {:optional, :string,
             description: "Time window the synthesis covered: all, week, or month."}
        }
      ),
      SimpleMCP.Tool.new(
        "cf_get_intel",
        "Read the latest competitor_intel for a product, or the last five when latest: false.",
        %{
          product_id: {:required, :string, description: "Product UUID."},
          latest:
            {:optional, :boolean,
             description: "Return the latest single row (default true) or the last five."}
        }
      ),
      SimpleMCP.Tool.new(
        "cf_list_pending_syntheses",
        "List pending competitor-intel syntheses for a product. Each row carries the source post ids the without-key route captured so a Claude session can pull the bundle via cf_top_posts_for_synthesis and complete via cf_store_intel.",
        %{
          product_id: {:required, :string, description: "Product UUID."}
        }
      ),
      SimpleMCP.Tool.new(
        "cf_import_twitter_sqlite",
        "Import posts + comments from the standalone scraper's sqlite file. Registered in 17.3; full implementation lands in 17.5.",
        %{
          sqlite_path: {:required, :string, description: "Path to the source sqlite file."},
          competitor_id:
            {:required, :string, description: "Target competitor UUID for the imported rows."},
          since: {:optional, :string, description: "Optional ISO date lower bound."},
          until: {:optional, :string, description: "Optional ISO date upper bound."}
        }
      ),
      SimpleMCP.Tool.new(
        "cf_recent_scoreboard",
        "Phase 17.6 operator surface. Recent scoreboard outcomes per product: top winners + losers from the last 7 days plus an indication of whether the corrective trigger fired (a week-windowed competitor_intel row exists for the product within the last 24 hours). Use to verify the corrective loop is closing without trawling the DB.",
        %{
          product_id:
            {:optional, :string,
             description:
               "Optional product UUID to scope to a single product. When omitted, returns active products (>=1 published post in the last 90 days)."},
          limit:
            {:optional, :integer,
             description:
               "Cap on winners + losers returned per product (default 5, clamped to [1, 20])."}
        }
      ),
      SimpleMCP.Tool.new(
        "cf_publish_text",
        "Publish a text post to one or more social platforms for a product. Checks each platform for valid OAuth credentials before attempting.",
        %{
          product_id: {:required, :string, description: "Product UUID."},
          text: {:required, :string, description: "Post body text."},
          image_url:
            {:optional, :string,
             description: "Optional image URL (Twitter, Facebook, LinkedIn, Instagram only)."},
          platforms:
            {:optional, :string,
             description:
               "JSON-encoded list of platforms (default: all connected). Options: twitter, linkedin, reddit, facebook, instagram."}
        }
      ),
      SimpleMCP.Tool.new(
        "cf_publish_video",
        "Publish a completed VideoJob to one or more social platforms. The video must have finished encoding (final R2 key present). Downloads from R2, then uploads to each platform.",
        %{
          video_job_id: {:required, :string, description: "VideoJob UUID."},
          platforms:
            {:optional, :string,
             description:
               "JSON-encoded list of platforms (default: all connected). Options: youtube, twitter, facebook, instagram, linkedin, reddit."},
          product_id:
            {:optional, :string,
             description: "Product UUID (auto-derived from VideoJob if omitted)."}
        }
      ),
      SimpleMCP.Tool.new(
        "cf_platform_status",
        "Check which social platforms have valid OAuth credentials configured for a product.",
        %{
          product_id: {:required, :string, description: "Product UUID."}
        }
      ),
      SimpleMCP.Tool.new(
        "cf_list_published_posts",
        "List published posts for a product, optionally filtered by platform.",
        %{
          product_id: {:required, :string, description: "Product UUID."},
          platform:
            {:optional, :string,
             description:
               "Filter by platform: twitter, linkedin, reddit, facebook, instagram, youtube."},
          limit: {:optional, :integer, description: "Max results (default 50, max 200)."}
        }
      )
    ]
  end

  # --- dispatch -------------------------------------------------------------

  # Phase 16.5: every MCP tool call routes through the audit
  # wrapper so the dashboard + REST surface see every invocation
  # (channel = "mcp"). The per-tool dispatch lives in
  # `call_tool/2`; the @impl callback only times the call and
  # writes the audit row. Phase 16.6 adds an escalation
  # short-circuit before `call_tool/2`. Two exemptions:
  # `escalate_to_human` (re-escalation must always succeed) and
  # `cf_recent_scoreboard` (operator-facing read; harmless on an
  # escalated session).
  @impl true
  def handle_tool_call(name, args) do
    audit_ctx = %{channel: "mcp"}
    started_at = System.monotonic_time(:millisecond)
    invoked_at = DateTime.utc_now()
    args_map = if is_map(args), do: args, else: %{}

    result =
      case mcp_escalation_block(name, args_map) do
        {:block, holding_reply} ->
          {:error, %{code: "escalated", message: holding_reply, details: %{}}}

        :pass ->
          call_tool(name, args)
      end

    duration_ms = System.monotonic_time(:millisecond) - started_at

    _ =
      ContentForge.ToolAudit.log_invocation(name, audit_ctx, args_map, result, %{
        duration_ms: duration_ms,
        invoked_at: invoked_at
      })

    result
  end

  defp mcp_escalation_block(name, _args)
       when name in ["escalate_to_human", "cf_recent_scoreboard"],
       do: :pass

  defp mcp_escalation_block(_name, args) do
    with id when is_binary(id) and id != "" <- Map.get(args, "product_id"),
         {:ok, uuid} <- Ecto.UUID.cast(id),
         %ContentForge.Escalations.EscalationEvent{} = event <-
           ContentForge.Escalations.find_open(uuid, "mcp",
             max_age_seconds: mcp_escalation_window()
           ) do
      {:block, event.holding_reply}
    else
      _ -> :pass
    end
  end

  defp mcp_escalation_window do
    Application.get_env(:content_forge, :escalations, [])
    |> Keyword.get(:session_window_seconds, 86_400)
  end

  defp call_tool("cf_create_product", args), do: cf_create_product(args)
  defp call_tool("cf_list_products", _args), do: cf_list_products()
  defp call_tool("cf_add_competitor", args), do: cf_add_competitor(args)
  defp call_tool("cf_list_competitors", args), do: cf_list_competitors(args)
  defp call_tool("cf_scrape_competitor", args), do: cf_scrape_competitor(args)
  defp call_tool("cf_top_posts_for_synthesis", args), do: cf_top_posts_for_synthesis(args)
  defp call_tool("cf_store_intel", args), do: cf_store_intel(args)
  defp call_tool("cf_get_intel", args), do: cf_get_intel(args)
  defp call_tool("cf_list_pending_syntheses", args), do: cf_list_pending_syntheses(args)
  defp call_tool("cf_import_twitter_sqlite", args), do: cf_import_twitter_sqlite(args)
  defp call_tool("cf_recent_scoreboard", args), do: cf_recent_scoreboard(args)
  defp call_tool("cf_publish_text", args), do: cf_publish_text(args)
  defp call_tool("cf_publish_video", args), do: cf_publish_video(args)
  defp call_tool("cf_platform_status", args), do: cf_platform_status(args)
  defp call_tool("cf_list_published_posts", args), do: cf_list_published_posts(args)

  defp call_tool(name, _args),
    do: error("not_found", "Unknown tool: #{name}")

  # --- cf_create_product ----------------------------------------------------

  defp cf_create_product(args) do
    with {:ok, name} <- require_binary(args, "name"),
         {:ok, attrs} <- build_create_product_attrs(name, args),
         {:ok, product} <- insert_product(attrs) do
      ok(%{product_id: product.id, name: product.name})
    end
  end

  defp build_create_product_attrs(name, args) do
    # Product schema requires voice_profile; pick a neutral
    # default when the MCP caller omits it so the spec's
    # "optional" param does not collide with the schema's NOT
    # NULL constraint.
    base = %{name: name, voice_profile: binary_param(args, "voice_profile") || "professional"}

    case binary_param(args, "publishing_targets") do
      nil ->
        {:ok, base}

      json ->
        case JSON.decode(json) do
          {:ok, map} when is_map(map) ->
            {:ok, Map.put(base, :publishing_targets, map)}

          _ ->
            error("validation_failed", "publishing_targets must be a JSON-encoded object", %{
              field: "publishing_targets"
            })
        end
    end
  end

  defp insert_product(attrs) do
    case Products.create_product(attrs) do
      {:ok, product} -> {:ok, product}
      {:error, changeset} -> changeset_error(changeset)
    end
  end

  # --- cf_list_products -----------------------------------------------------

  defp cf_list_products do
    products = Products.list_products()

    rows =
      Enum.map(products, fn %Product{} = p ->
        %{
          product_id: p.id,
          name: p.name,
          competitor_count: count_competitors(p.id),
          latest_intel_at: latest_intel_at(p.id)
        }
      end)

    ok(rows)
  end

  defp count_competitors(product_id) do
    Repo.aggregate(
      from(c in CompetitorAccount, where: c.product_id == ^product_id),
      :count,
      :id
    )
  end

  defp latest_intel_at(product_id) do
    case Products.get_latest_competitor_intel_for_product(product_id) do
      %CompetitorIntel{inserted_at: at} -> iso8601(at)
      _ -> nil
    end
  end

  # --- cf_add_competitor ----------------------------------------------------

  defp cf_add_competitor(args) do
    with {:ok, product_id} <- require_binary(args, "product_id"),
         {:ok, _product} <- fetch_product(product_id),
         {:ok, platform} <- require_platform(args),
         {:ok, handle} <- require_binary(args, "handle"),
         {:ok, account} <-
           insert_competitor(%{
             product_id: product_id,
             platform: platform,
             handle: handle
           }) do
      ok(%{
        competitor_id: account.id,
        product_id: account.product_id,
        platform: account.platform,
        handle: account.handle
      })
    end
  end

  defp insert_competitor(attrs) do
    case Products.create_competitor_account(attrs) do
      {:ok, account} -> {:ok, account}
      {:error, changeset} -> changeset_error(changeset)
    end
  end

  defp require_platform(args) do
    case binary_param(args, "platform") do
      nil ->
        error("validation_failed", "platform is required", %{field: "platform"})

      value ->
        if value in @platforms do
          {:ok, value}
        else
          error("validation_failed", "platform must be one of #{Enum.join(@platforms, ", ")}", %{
            field: "platform",
            allowed: @platforms
          })
        end
    end
  end

  # --- cf_list_competitors --------------------------------------------------

  defp cf_list_competitors(args) do
    with {:ok, product_id} <- require_binary(args, "product_id"),
         {:ok, _product} <- fetch_product(product_id) do
      accounts = Products.list_competitor_accounts_for_product(product_id)

      rows =
        Enum.map(accounts, fn %CompetitorAccount{} = a ->
          {count, last_at} = competitor_post_stats(a.id)

          %{
            competitor_id: a.id,
            platform: a.platform,
            handle: a.handle,
            post_count: count,
            last_scraped_at: iso8601(last_at)
          }
        end)

      ok(rows)
    end
  end

  defp competitor_post_stats(account_id) do
    Repo.one(
      from(c in CompetitorPost,
        where: c.competitor_account_id == ^account_id,
        select: {count(c.id), max(c.inserted_at)}
      )
    ) || {0, nil}
  end

  # --- cf_scrape_competitor -------------------------------------------------

  defp cf_scrape_competitor(args) do
    with {:ok, competitor_id} <- require_binary(args, "competitor_id"),
         {:ok, account} <- fetch_competitor(competitor_id),
         {:ok, job} <- enqueue_scrape(account.product_id) do
      ok(%{job_id: job.id, status: "enqueued"})
    end
  end

  defp enqueue_scrape(product_id) do
    case %{"product_id" => product_id} |> CompetitorScraper.new() |> Oban.insert() do
      {:ok, job} ->
        {:ok, job}

      {:error, reason} ->
        error("dependency_error", "Failed to enqueue scrape", %{reason: inspect(reason)})
    end
  end

  # --- cf_top_posts_for_synthesis -------------------------------------------

  defp cf_top_posts_for_synthesis(args) do
    with {:ok, product_id} <- require_binary(args, "product_id"),
         {:ok, _product} <- fetch_product(product_id),
         {:ok, n} <- fetch_n(args),
         {:ok, window} <- fetch_window(args, "all") do
      posts = top_posts(product_id, n, window) |> Repo.preload(:comments)
      ok(%{posts: Enum.map(posts, &serialize_post/1)})
    end
  end

  defp fetch_n(args) do
    case Map.get(args, "n", @top_posts_default) do
      n when is_integer(n) and n > 0 -> {:ok, min(n, @top_posts_max)}
      _ -> error("validation_failed", "n must be a positive integer", %{field: "n"})
    end
  end

  defp fetch_window(args, default) do
    value = binary_param(args, "window") || default

    if value in @windows do
      {:ok, value}
    else
      error("validation_failed", "window must be one of #{Enum.join(@windows, ", ")}", %{
        field: "window",
        allowed: @windows
      })
    end
  end

  defp top_posts(product_id, n, window) do
    account_ids =
      product_id
      |> Products.list_active_competitor_accounts_for_product()
      |> Enum.map(& &1.id)

    base =
      from(p in CompetitorPost,
        where: p.competitor_account_id in ^account_ids,
        order_by: [desc: p.engagement_score],
        limit: ^n
      )

    case window_cutoff(window) do
      nil -> Repo.all(base)
      cutoff -> Repo.all(from(p in base, where: p.posted_at >= ^cutoff))
    end
  end

  defp window_cutoff("all"), do: nil
  defp window_cutoff("week"), do: DateTime.add(DateTime.utc_now(), -7 * 24 * 3600, :second)
  defp window_cutoff("month"), do: DateTime.add(DateTime.utc_now(), -30 * 24 * 3600, :second)

  defp serialize_post(%CompetitorPost{} = post) do
    %{
      competitor_post_id: post.id,
      platform_post_id: post.post_id,
      content: post.content,
      post_url: post.post_url,
      posted_at: iso8601(post.posted_at),
      engagement_score: post.engagement_score,
      likes: post.likes_count,
      comments_count: post.comments_count,
      shares: post.shares_count,
      views: post.views_count,
      conversation_id: post.conversation_id,
      comments: Enum.map(post.comments || [], &serialize_comment/1)
    }
  end

  defp serialize_comment(comment) do
    %{
      platform_comment_id: comment.platform_comment_id,
      author_handle: comment.author_handle,
      text: comment.text,
      likes_count: comment.likes_count,
      posted_at: iso8601(comment.posted_at)
    }
  end

  # --- cf_store_intel -------------------------------------------------------

  defp cf_store_intel(args) do
    with {:ok, product_id} <- require_binary(args, "product_id"),
         {:ok, _product} <- fetch_product(product_id),
         {:ok, summary} <- require_binary(args, "summary"),
         {:ok, trending_topics} <- require_string_list(args, "trending_topics"),
         {:ok, winning_formats} <- require_string_list(args, "winning_formats"),
         {:ok, effective_hooks} <- require_string_list(args, "effective_hooks"),
         {:ok, audience_signals} <- require_string_list(args, "audience_signals"),
         {:ok, source_count} <- require_positive_integer(args, "source_count"),
         {:ok, window} <- fetch_optional_window(args),
         {:ok, intel} <-
           insert_intel(%{
             product_id: product_id,
             summary: summary,
             trending_topics: trending_topics,
             winning_formats: winning_formats,
             effective_hooks: effective_hooks,
             audience_signals: audience_signals,
             source_count: source_count,
             window: window
           }) do
      # Resolve any pending-synthesis rows for the same
      # (product, window) so the MCP queue stays bounded.
      _resolved = Products.resolve_pending_intel_syntheses(product_id, window)

      ok(%{
        intel_id: intel.id,
        product_id: intel.product_id,
        created_at: iso8601(intel.inserted_at)
      })
    end
  end

  defp insert_intel(attrs) do
    case Products.create_competitor_intel(attrs) do
      {:ok, intel} -> {:ok, intel}
      {:error, changeset} -> changeset_error(changeset)
    end
  end

  defp fetch_optional_window(args) do
    case binary_param(args, "window") do
      nil ->
        {:ok, nil}

      value ->
        if value in @windows,
          do: {:ok, value},
          else:
            error("validation_failed", "window must be one of #{Enum.join(@windows, ", ")}", %{
              field: "window"
            })
    end
  end

  # --- cf_get_intel ---------------------------------------------------------

  defp cf_get_intel(args) do
    with {:ok, product_id} <- require_binary(args, "product_id"),
         {:ok, _product} <- fetch_product(product_id) do
      latest_flag = Map.get(args, "latest", true)
      do_get_intel(product_id, latest_flag)
    end
  end

  defp do_get_intel(product_id, true) do
    case Products.get_latest_competitor_intel_for_product(product_id) do
      nil ->
        error("not_found", "No competitor_intel for product yet", %{product_id: product_id})

      %CompetitorIntel{} = intel ->
        ok(serialize_intel(intel))
    end
  end

  defp do_get_intel(product_id, false) do
    rows =
      product_id
      |> Products.list_competitor_intel_for_product()
      |> Enum.take(5)
      |> Enum.map(&serialize_intel/1)

    ok(rows)
  end

  defp serialize_intel(%CompetitorIntel{} = intel) do
    %{
      intel_id: intel.id,
      summary: intel.summary,
      trending_topics: intel.trending_topics || [],
      winning_formats: intel.winning_formats || [],
      effective_hooks: intel.effective_hooks || [],
      audience_signals: intel.audience_signals || [],
      source_count: intel.source_count,
      window: intel.window,
      created_at: iso8601(intel.inserted_at)
    }
  end

  # --- cf_list_pending_syntheses --------------------------------------------

  defp cf_list_pending_syntheses(args) do
    with {:ok, product_id} <- require_binary(args, "product_id"),
         {:ok, _product} <- fetch_product(product_id) do
      rows =
        product_id
        |> Products.list_pending_intel_syntheses_for_product()
        |> Enum.map(&serialize_pending/1)

      ok(rows)
    end
  end

  defp serialize_pending(%PendingIntelSynthesis{} = row) do
    %{
      pending_id: row.id,
      product_id: row.product_id,
      window: row.window,
      source_post_ids: row.source_post_ids || [],
      note: row.note,
      created_at: iso8601(row.inserted_at)
    }
  end

  # --- cf_import_twitter_sqlite ---------------------------------------------

  defp cf_import_twitter_sqlite(args) do
    with {:ok, sqlite_path} <- require_binary(args, "sqlite_path"),
         {:ok, competitor_id} <- require_binary(args, "competitor_id"),
         {:ok, competitor} <- fetch_competitor(competitor_id),
         since <- binary_param(args, "since"),
         until_value <- binary_param(args, "until") do
      do_import_twitter_sqlite(sqlite_path, competitor, since, until_value)
    end
  end

  defp do_import_twitter_sqlite(sqlite_path, competitor, since, until_value) do
    case SqliteImporter.import_twitter_sqlite(%{
           sqlite_path: sqlite_path,
           competitor: competitor,
           since: since,
           until: until_value
         }) do
      {:ok, result} ->
        ok(result)

      {:error, :sqlite_not_found} ->
        error("not_found", "Source sqlite file not found", %{sqlite_path: sqlite_path})

      {:error, {:sqlite_open_failed, reason}} ->
        error("dependency_error", "Failed to open source sqlite", %{reason: inspect(reason)})

      {:error, reason} ->
        error("dependency_error", "Importer failed", %{reason: inspect(reason)})
    end
  end

  # --- cf_recent_scoreboard -------------------------------------------------

  @scoreboard_default_limit 5
  @scoreboard_max_limit 20
  @corrective_window_hours 24
  @scoreboard_lookback_days 7

  defp cf_recent_scoreboard(args) do
    limit = clamp_scoreboard_limit(args["limit"] || args[:limit])

    case binary_param(args, "product_id") do
      nil ->
        rows =
          MetricsPollerScheduler.active_product_ids()
          |> Enum.map(&scoreboard_summary_for(&1, limit))
          |> Enum.reject(&is_nil/1)

        ok(%{products: rows})

      product_id ->
        with {:ok, product} <- fetch_product(product_id) do
          ok(%{products: [build_scoreboard_summary(product, limit)]})
        end
    end
  end

  defp clamp_scoreboard_limit(value) when is_integer(value) and value >= 1,
    do: min(value, @scoreboard_max_limit)

  defp clamp_scoreboard_limit(_), do: @scoreboard_default_limit

  defp scoreboard_summary_for(product_id, limit) do
    case safe_get_product(product_id) do
      %Product{} = product -> build_scoreboard_summary(product, limit)
      _ -> nil
    end
  end

  defp build_scoreboard_summary(%Product{} = product, limit) do
    cutoff =
      DateTime.utc_now()
      |> DateTime.add(-@scoreboard_lookback_days * 24 * 3600, :second)

    entries =
      Repo.all(
        from(s in ScoreboardEntry,
          where: s.product_id == ^product.id and s.measured_at >= ^cutoff,
          order_by: [desc: s.measured_at]
        )
      )

    winners =
      entries
      |> Enum.filter(&(&1.outcome == "winner"))
      |> Enum.take(limit)
      |> Enum.map(&serialize_scoreboard_entry/1)

    losers =
      entries
      |> Enum.filter(&(&1.outcome == "loser"))
      |> Enum.take(limit)
      |> Enum.map(&serialize_scoreboard_entry/1)

    last_polled_at =
      case entries do
        [latest | _] -> iso8601(latest.measured_at)
        [] -> nil
      end

    %{
      product_id: product.id,
      product_name: product.name,
      window_days: @scoreboard_lookback_days,
      recent_winners: winners,
      recent_losers: losers,
      corrective_trigger_fired: corrective_trigger_fired?(product.id),
      last_polled_at: last_polled_at
    }
  end

  defp serialize_scoreboard_entry(%ScoreboardEntry{} = entry) do
    %{
      content_id: entry.content_id,
      platform: entry.platform,
      angle: entry.angle,
      delta: entry.delta,
      composite_ai_score: entry.composite_ai_score,
      actual_engagement_score: entry.actual_engagement_score,
      measured_at: iso8601(entry.measured_at)
    }
  end

  defp corrective_trigger_fired?(product_id) do
    cutoff =
      DateTime.utc_now()
      |> DateTime.add(-@corrective_window_hours * 3600, :second)

    Repo.exists?(
      from(intel in CompetitorIntel,
        where:
          intel.product_id == ^product_id and
            intel.window == "week" and
            intel.inserted_at >= ^cutoff
      )
    )
  end

  # --- cf_publish_text ------------------------------------------------------

  # Phase 16.7: every cf_publish_text call routes through the
  # Draft pipeline. Either (a) the caller passes an existing
  # `draft_id` and that Draft is reused across all requested
  # platforms (with per-platform skip for already-published
  # `(draft_id, platform)` pairs - the idempotency primitive), or
  # (b) the tool auto-creates one Draft per platform with
  # `status: "approved"` + `generating_model:
  # "agent:cf_publish_text:<sender>"` before fan-out. Either
  # way, every PublishedPost row gets a non-nil draft_id, so
  # cf_publish_text posts flow into the scoreboard /
  # corrective-loop pipeline the same as AI-generated content.
  #
  # `:submitter` is the minimum role per the 16.3/16.4 light-vs-
  # heavy-write split (PR #2 rework).
  defp cf_publish_text(args) do
    with {:ok, product_id} <- require_binary(args, "product_id"),
         {:ok, product} <- fetch_product(product_id),
         :ok <- Authorization.require(mcp_ctx(product), :submitter),
         {:ok, text} <- require_binary(args, "text") do
      do_cf_publish_text(args, product, text)
    else
      {:error, :forbidden} -> error("forbidden", "Insufficient role for cf_publish_text")
      other -> other
    end
  end

  defp do_cf_publish_text(args, product, text) do
    image_url = binary_param(args, "image_url")
    angle = binary_param(args, "angle") || "direct"
    sender = binary_param(args, "sender_identity") || "unknown"
    requested = resolve_text_platforms(args, product)

    case resolve_text_drafts(args, product, text, angle, sender, requested) do
      {:error, error_envelope} ->
        error_envelope

      {:ok, drafts_by_platform} ->
        published_already =
          published_platforms_for(product, Map.values(drafts_by_platform) |> Enum.uniq())

        {to_publish, skipped} =
          partition_skipped(requested, drafts_by_platform, published_already)

        fan_out_results =
          Publishing.publish_text(product, text, image_url, to_publish,
            draft_ids_by_platform: drafts_by_platform
          )

        serialized =
          fan_out_results
          |> Enum.map(fn {p, r} -> serialize_publish_result(p, r) end)
          |> Map.new()

        serialized_with_skips =
          Enum.reduce(skipped, serialized, fn p, acc ->
            Map.put(acc, p, %{status: "skipped_already_published"})
          end)

        ok(%{
          product_id: product.id,
          text_preview: String.slice(text, 0, 80),
          drafts: drafts_by_platform,
          results: serialized_with_skips,
          total_attempted: map_size(serialized),
          total_succeeded: Enum.count(serialized, fn {_, r} -> r[:status] == "success" end),
          total_skipped: length(skipped)
        })
    end
  end

  defp resolve_text_platforms(args, product) do
    connected = Publishing.connected_platforms(product)

    platforms =
      case parse_platforms(args, "platforms", connected) do
        {:ok, p} -> p
        _ -> connected
      end

    not_connected = platforms -- connected

    if not_connected != [] do
      Logger.info("cf_publish_text: platforms missing credentials: #{inspect(not_connected)}")
    end

    Enum.uniq(platforms)
  end

  # When the caller passes an explicit draft_id, every requested
  # platform shares it. Otherwise auto-create one Draft per
  # platform.
  defp resolve_text_drafts(args, product, text, angle, sender, platforms) do
    case binary_param(args, "draft_id") do
      nil -> autocreate_drafts(product, text, angle, sender, platforms)
      draft_id -> reuse_draft(product, draft_id, platforms)
    end
  end

  defp autocreate_drafts(product, text, angle, sender, platforms) do
    Enum.reduce_while(platforms, {:ok, %{}}, fn platform, {:ok, acc} ->
      attrs = %{
        product_id: product.id,
        platform: platform,
        content_type: "post",
        angle: angle,
        content: text,
        generating_model: "agent:cf_publish_text:#{sender}",
        status: "approved"
      }

      case ContentGeneration.create_draft(attrs) do
        {:ok, draft} ->
          {:cont, {:ok, Map.put(acc, platform, draft.id)}}

        {:error, _changeset} ->
          {:halt, {:error, error("validation_failed", "draft insert failed")}}
      end
    end)
  end

  defp reuse_draft(product, draft_id, platforms) do
    case fetch_owned_draft(product.id, draft_id) do
      {:ok, draft} ->
        {:ok, Map.new(platforms, &{&1, draft.id})}

      :not_found ->
        {:error, error("not_found", "Draft not found for this product", %{draft_id: draft_id})}
    end
  end

  defp fetch_owned_draft(product_id, draft_id) do
    case Ecto.UUID.cast(draft_id) do
      {:ok, _} ->
        case ContentGeneration.get_draft(draft_id) do
          %{product_id: ^product_id} = draft -> {:ok, draft}
          _ -> :not_found
        end

      :error ->
        :not_found
    end
  end

  defp published_platforms_for(_product, []), do: MapSet.new()

  defp published_platforms_for(product, draft_ids) do
    rows = Publishing.list_published_posts(product_id: product.id)

    rows
    |> Enum.filter(&(&1.draft_id in draft_ids))
    |> Enum.map(&{&1.draft_id, &1.platform})
    |> MapSet.new()
  end

  defp partition_skipped(platforms, drafts_by_platform, published_set) do
    Enum.split_with(platforms, fn platform ->
      draft_id = Map.get(drafts_by_platform, platform)
      not MapSet.member?(published_set, {draft_id, platform})
    end)
  end

  # --- cf_publish_video ------------------------------------------------------

  # Phase 16-tail rework: video publishing is irreversible
  # (YouTube uploads are durable; cross-posts hit external
  # platforms that bill per call) and gets the full 16.4
  # heavy-write treatment: `:owner` Authorization gate + the
  # two-turn Confirmation envelope.
  #
  # First call (no `confirm` arg): returns an MCP-shaped envelope
  # with `confirmation_required: true`, an `echo_phrase` the
  # caller reads back, and a `preview` listing target platforms.
  # Second call (`confirm` arg supplied): validates the phrase
  # via `Confirmation.confirm/4`, then proceeds with the fan-out.
  defp cf_publish_video(args) do
    with {:ok, video_job_id} <- require_binary(args, "video_job_id"),
         {:ok, video_job} <- fetch_video_job(video_job_id),
         {:ok, product} <-
           fetch_product(binary_param(args, "product_id") || video_job.product_id),
         :ok <- Authorization.require(mcp_ctx(product), :owner) do
      dispatch_publish_video_turn(args, video_job, product)
    else
      {:error, :forbidden} -> error("forbidden", "Insufficient role for cf_publish_video")
      other -> other
    end
  end

  defp dispatch_publish_video_turn(args, video_job, product) do
    platforms = resolve_publish_platforms(args, product, video_job)

    case binary_param(args, "confirm") do
      nil -> request_publish_video_confirmation(args, video_job, product, platforms)
      echo -> confirm_publish_video(args, echo, video_job, product, platforms)
    end
  end

  defp resolve_publish_platforms(args, product, video_job) do
    default = Publishing.connected_platforms(product) -- (video_job.published_platforms || [])

    case parse_platforms(args, "platforms", default) do
      {:ok, p} -> p
      _ -> default
    end
  end

  defp request_publish_video_confirmation(args, video_job, product, platforms) do
    preview = %{
      summary:
        "Publish video #{video_job.id} to #{length(platforms)} platform(s). " <>
          "Cross-posts hit external APIs and may incur platform-specific costs.",
      product_id: product.id,
      platform: Enum.join(platforms, ",")
    }

    case Confirmation.request("cf_publish_video", mcp_session_ctx(), args, preview) do
      {:ok, envelope} ->
        ok(%{
          confirmation_required: true,
          echo_phrase: envelope.echo_phrase,
          expires_at: iso8601(envelope.expires_at),
          preview: preview,
          platforms: platforms
        })

      {:error, reason} ->
        error("confirmation_request_failed", to_string(reason))
    end
  end

  defp confirm_publish_video(args, echo, video_job, product, platforms) do
    case Confirmation.confirm("cf_publish_video", mcp_session_ctx(), args, echo) do
      :ok ->
        do_publish_video(video_job, product, platforms)

      {:error, :confirmation_mismatch} ->
        error("confirmation_mismatch", "Echo phrase did not match the pending confirmation")

      {:error, :confirmation_not_found} ->
        error("confirmation_not_found", "No pending confirmation matches that echo phrase")

      {:error, :confirmation_expired} ->
        error("confirmation_expired", "The pending confirmation has expired; request a new one")

      {:error, reason} ->
        error("confirmation_failed", to_string(reason))
    end
  end

  defp do_publish_video(video_job, product, platforms) do
    case Publishing.publish_video(video_job, platforms, product) do
      {:error, reason} ->
        error("publish_failed", to_string(reason), %{video_job_id: video_job.id})

      results when is_map(results) ->
        serialized =
          results
          |> Enum.map(fn {platform, result} -> serialize_publish_result(platform, result) end)
          |> Map.new()

        Enum.each(results, fn
          {platform, {:ok, _}} -> Publishing.record_video_published(video_job, platform)
          _ -> :ok
        end)

        succeeded_platforms =
          results
          |> Enum.filter(fn {_, r} -> match?({:ok, _}, r) end)
          |> Enum.map(fn {p, _} -> p end)

        ok(%{
          video_job_id: video_job.id,
          product_id: product.id,
          results: serialized,
          all_published_platforms:
            Enum.uniq((video_job.published_platforms || []) ++ succeeded_platforms),
          total_attempted: map_size(serialized),
          total_succeeded: length(succeeded_platforms)
        })
    end
  end

  defp mcp_ctx(product) do
    %{channel: "mcp", sender_identity: "mcp", product: product}
  end

  defp mcp_session_ctx do
    %{session_id: "mcp"}
  end

  # --- cf_platform_status ---------------------------------------------------

  defp cf_platform_status(args) do
    with {:ok, product_id} <- require_binary(args, "product_id"),
         {:ok, product} <- fetch_product(product_id) do
      status = Publishing.platform_status(product)
      connected = Publishing.connected_platforms(product)

      ok(%{
        product_id: product_id,
        connected_count: length(connected),
        connected: connected,
        platforms: status
      })
    end
  end

  # --- cf_list_published_posts ----------------------------------------------

  defp cf_list_published_posts(args) do
    with {:ok, product_id} <- require_binary(args, "product_id"),
         {:ok, _product} <- fetch_product(product_id) do
      opts =
        []
        |> maybe_put_platform(binary_param(args, "platform"))
        |> maybe_put_limit(args["limit"] || args[:limit] || 50)

      posts = Publishing.list_published_posts([{:product_id, product_id} | opts])

      serialized = Enum.map(posts, &serialize_published_post/1)

      ok(%{product_id: product_id, count: length(serialized), posts: serialized})
    end
  end

  # ============================================
  # Helpers
  # ============================================

  defp parse_platforms(args, key, default) do
    case Map.get(args, key) do
      list when is_list(list) ->
        {:ok, list}

      json when is_binary(json) ->
        case JSON.decode(json) do
          {:ok, list} when is_list(list) -> {:ok, list}
          _ -> {:ok, default}
        end

      nil ->
        {:ok, default}

      _ ->
        {:ok, default}
    end
  end

  defp serialize_publish_result(platform, {:ok, %{post_id: id, post_url: url}}) do
    {platform, %{status: "success", post_id: id, post_url: url}}
  end

  defp serialize_publish_result(platform, {:error, reason}) do
    {platform, %{status: "failed", error: reason}}
  end

  defp serialize_published_post(%Publishing.PublishedPost{} = post) do
    %{
      id: post.id,
      platform: post.platform,
      platform_post_id: post.platform_post_id,
      platform_post_url: post.platform_post_url,
      posted_at: iso8601(post.posted_at),
      engagement_data: post.engagement_data
    }
  end

  defp fetch_video_job(id) do
    case Publishing.get_video_job(id) do
      %VideoJob{} = job -> {:ok, job}
      _ -> {:error, "VideoJob not found", %{video_job_id: id}}
    end
  rescue
    Ecto.Query.CastError -> {:error, "Invalid VideoJob ID format", %{video_job_id: id}}
  end

  defp maybe_put_platform(opts, nil), do: opts
  defp maybe_put_platform(opts, platform), do: [{:platform, platform} | opts]

  defp maybe_put_limit(opts, n) when is_integer(n) and n > 0, do: [{:limit, min(n, 200)} | opts]
  defp maybe_put_limit(opts, _), do: opts

  # --- product / competitor lookups -----------------------------------------

  defp fetch_product(product_id) do
    case safe_get_product(product_id) do
      %Product{} = product -> {:ok, product}
      _ -> error("not_found", "Product not found", %{product_id: product_id})
    end
  end

  defp safe_get_product(id) do
    Products.get_product(id)
  rescue
    Ecto.Query.CastError -> nil
  end

  defp fetch_competitor(competitor_id) do
    case safe_get_competitor(competitor_id) do
      %CompetitorAccount{} = account -> {:ok, account}
      _ -> error("not_found", "Competitor not found", %{competitor_id: competitor_id})
    end
  end

  defp safe_get_competitor(id) do
    Products.get_competitor_account(id)
  rescue
    Ecto.Query.CastError -> nil
  end

  # --- param helpers --------------------------------------------------------

  defp require_binary(args, key) do
    case binary_param(args, key) do
      nil -> error("validation_failed", "#{key} is required", %{field: key})
      value -> {:ok, value}
    end
  end

  defp binary_param(args, key) do
    case Map.get(args, key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp require_string_list(args, key) do
    case Map.get(args, key) do
      list when is_list(list) ->
        if Enum.all?(list, &is_binary/1),
          do: {:ok, list},
          else: error("validation_failed", "#{key} must be a list of strings", %{field: key})

      json when is_binary(json) ->
        case JSON.decode(json) do
          {:ok, list} when is_list(list) ->
            if Enum.all?(list, &is_binary/1),
              do: {:ok, list},
              else: error("validation_failed", "#{key} must be a list of strings", %{field: key})

          _ ->
            error("validation_failed", "#{key} must be a JSON-encoded list of strings", %{
              field: key
            })
        end

      _ ->
        error("validation_failed", "#{key} is required", %{field: key})
    end
  end

  defp require_positive_integer(args, key) do
    case Map.get(args, key) do
      n when is_integer(n) and n >= 0 -> {:ok, n}
      _ -> error("validation_failed", "#{key} must be a non-negative integer", %{field: key})
    end
  end

  # --- envelope helpers -----------------------------------------------------

  defp ok(result), do: {:ok, result}

  defp error(code, message, details \\ %{}) do
    {:error, %{code: code, message: message, details: details}}
  end

  defp changeset_error(%Ecto.Changeset{errors: errors} = cs) do
    error("validation_failed", "Changeset error", %{
      errors: Map.new(errors, fn {field, {msg, _opts}} -> {field, msg} end),
      changeset: inspect(cs.changes)
    })
  end

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp iso8601(%NaiveDateTime{} = ndt) do
    ndt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()
  end
end
