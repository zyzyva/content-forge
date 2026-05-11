defmodule ContentForge.Jobs.CompetitorCommentHarvesterTest do
  @moduledoc """
  Phase 17.1: harvester worker tests. Verifies the happy path
  upserts comments into the new corpus table, idempotent re-runs
  insert zero rows, and adapter failure modes (missing token,
  missing conversation, transient vs permanent) classify
  correctly.
  """
  use ContentForge.DataCase, async: false

  alias ContentForge.Jobs.CompetitorCommentHarvester
  alias ContentForge.Products
  alias ContentForge.Products.CompetitorPostComment
  alias ContentForge.Repo

  defmodule StubAdapter do
    @moduledoc false

    def fetch_comments(post, opts) do
      pid = Application.fetch_env!(:content_forge, :stub_adapter_pid)
      send(pid, {:fetch_comments_called, post.id, opts})

      Application.fetch_env!(:content_forge, :stub_adapter_response)
    end

    def fetch_posts(_account), do: {:error, :unsupported_for_test}
  end

  setup do
    {:ok, product} =
      Products.create_product(%{name: "RivalLand", voice_profile: "warm"})

    {:ok, account} =
      Products.create_competitor_account(%{
        product_id: product.id,
        platform: "twitter",
        handle: "rival",
        active: true
      })

    {:ok, post} =
      Products.create_competitor_post(%{
        competitor_account_id: account.id,
        post_id: "p1",
        content: "viral post",
        posted_at: DateTime.utc_now() |> DateTime.truncate(:second),
        views_count: 250_000,
        conversation_id: "conv-1"
      })

    original_adapter = Application.get_env(:content_forge, :scraper_adapter)
    Application.put_env(:content_forge, :scraper_adapter, StubAdapter)
    Application.put_env(:content_forge, :stub_adapter_pid, self())

    on_exit(fn ->
      if is_nil(original_adapter) do
        Application.delete_env(:content_forge, :scraper_adapter)
      else
        Application.put_env(:content_forge, :scraper_adapter, original_adapter)
      end

      Application.delete_env(:content_forge, :stub_adapter_pid)
      Application.delete_env(:content_forge, :stub_adapter_response)
    end)

    %{product: product, account: account, post: post}
  end

  defp comment_attrs(post, comment_id, attrs \\ %{}) do
    Map.merge(
      %{
        competitor_post_id: post.id,
        platform_comment_id: comment_id,
        author_handle: "fan",
        text: "ok",
        likes_count: 5,
        conversation_id: "conv-1",
        raw_payload: %{"id" => comment_id}
      },
      attrs
    )
  end

  defp run(post_id, args \\ %{}) do
    job = %Oban.Job{args: Map.put(args, "competitor_post_id", post_id)}
    CompetitorCommentHarvester.perform(job)
  end

  describe "perform/1 happy path" do
    test "upserts every comment the adapter returned and returns :ok",
         %{post: post} do
      Application.put_env(
        :content_forge,
        :stub_adapter_response,
        {:ok,
         [
           comment_attrs(post, "c1", %{likes_count: 9, text: "first"}),
           comment_attrs(post, "c2", %{likes_count: 4, text: "second"})
         ]}
      )

      assert :ok = run(post.id)

      rows = Products.list_comments_for_post(post.id)
      assert length(rows) == 2
      assert Enum.map(rows, & &1.platform_comment_id) == ["c1", "c2"]
    end

    test "passes platform from the post's account to the adapter",
         %{post: post} do
      Application.put_env(:content_forge, :stub_adapter_response, {:ok, []})

      assert :ok = run(post.id)
      assert_received {:fetch_comments_called, _post_id, opts}
      assert opts[:platform] == "twitter"
    end

    test "limit override threads through to the adapter call",
         %{post: post} do
      Application.put_env(:content_forge, :stub_adapter_response, {:ok, []})

      assert :ok = run(post.id, %{"limit" => 12})
      assert_received {:fetch_comments_called, _post_id, opts}
      assert opts[:limit] == 12
    end

    test "re-running over the same harvest result inserts zero new rows",
         %{post: post} do
      Application.put_env(
        :content_forge,
        :stub_adapter_response,
        {:ok, [comment_attrs(post, "c1", %{likes_count: 5})]}
      )

      assert :ok = run(post.id)
      assert :ok = run(post.id)

      assert Repo.aggregate(CompetitorPostComment, :count, :id) == 1
    end
  end

  describe "perform/1 failure modes" do
    test "missing competitor_post_id arg returns {:cancel, :missing_competitor_post_id}" do
      assert {:cancel, :missing_competitor_post_id} =
               CompetitorCommentHarvester.perform(%Oban.Job{args: %{}})
    end

    test "unknown post id cancels with :post_not_found" do
      assert {:cancel, :post_not_found} = run(Ecto.UUID.generate())
    end

    test "malformed post id cancels with :post_not_found" do
      assert {:cancel, :post_not_found} = run("not-a-uuid")
    end

    test "missing scraper adapter cancels", %{post: post} do
      Application.delete_env(:content_forge, :scraper_adapter)
      assert {:cancel, :scraper_adapter_not_configured} = run(post.id)
    end

    test "adapter :not_configured cancels with the same reason", %{post: post} do
      Application.put_env(:content_forge, :stub_adapter_response, {:error, :not_configured})
      assert {:cancel, :scraper_adapter_not_configured} = run(post.id)
    end

    test "adapter :missing_conversation_id cancels", %{post: post} do
      Application.put_env(
        :content_forge,
        :stub_adapter_response,
        {:error, :missing_conversation_id}
      )

      assert {:cancel, :missing_conversation_id} = run(post.id)
    end

    test "adapter transient error returns :error so Oban retries", %{post: post} do
      Application.put_env(:content_forge, :stub_adapter_response, error: nil)

      Application.put_env(
        :content_forge,
        :stub_adapter_response,
        {:error, {:transient, 503, "boom"}}
      )

      assert {:error, {:transient, 503, "boom"}} = run(post.id)
    end

    test "adapter permanent error cancels", %{post: post} do
      Application.put_env(
        :content_forge,
        :stub_adapter_response,
        {:error, {:http_error, 400, "bad"}}
      )

      assert {:cancel, {:http_error, 400, "bad"}} = run(post.id)
    end
  end
end
