defmodule ContentForge.Products.CompetitorPostCommentTest do
  @moduledoc """
  Phase 17.1: schema + upsert behavior for the new comment corpus
  attached to viral competitor posts. Locks in the idempotent
  upsert path the harvester relies on, plus the partial-unique
  guarantees the DB enforces.
  """
  use ContentForge.DataCase, async: false

  alias ContentForge.Products
  alias ContentForge.Products.CompetitorPost
  alias ContentForge.Products.CompetitorPostComment
  alias ContentForge.Repo

  defp insert_account!(product) do
    {:ok, account} =
      Products.create_competitor_account(%{
        product_id: product.id,
        platform: "twitter",
        handle: "rivalcorp",
        url: "https://x.com/rivalcorp",
        active: true
      })

    account
  end

  defp insert_post!(account, attrs \\ %{}) do
    {:ok, post} =
      Products.create_competitor_post(
        Map.merge(
          %{
            competitor_account_id: account.id,
            post_id: "p-1",
            content: "viral post body",
            posted_at: DateTime.utc_now() |> DateTime.truncate(:second),
            likes_count: 1000,
            comments_count: 50,
            shares_count: 100,
            views_count: 200_000,
            conversation_id: "conv-1"
          },
          attrs
        )
      )

    post
  end

  setup do
    {:ok, product} =
      Products.create_product(%{name: "RivalLand", voice_profile: "warm"})

    account = insert_account!(product)
    post = insert_post!(account)

    %{product: product, account: account, post: post}
  end

  describe "upsert_competitor_post_comment/1" do
    test "inserts a new comment with required fields", %{post: post} do
      assert {:ok, %CompetitorPostComment{} = c} =
               Products.upsert_competitor_post_comment(%{
                 competitor_post_id: post.id,
                 platform_comment_id: "comment-1",
                 author_handle: "fan42",
                 text: "love this",
                 posted_at: DateTime.utc_now() |> DateTime.truncate(:second),
                 likes_count: 5,
                 conversation_id: "conv-1",
                 raw_payload: %{"raw" => true}
               })

      assert c.competitor_post_id == post.id
      assert c.platform_comment_id == "comment-1"
      assert c.likes_count == 5
      assert c.replies_count == 0
      assert c.author_handle == "fan42"
      assert c.text == "love this"
    end

    test "second upsert with the same (post, platform_comment_id) refreshes counts in place",
         %{post: post} do
      attrs = fn likes ->
        %{
          competitor_post_id: post.id,
          platform_comment_id: "comment-2",
          author_handle: "fan42",
          text: "great point",
          likes_count: likes
        }
      end

      assert {:ok, first} = Products.upsert_competitor_post_comment(attrs.(3))
      assert {:ok, second} = Products.upsert_competitor_post_comment(attrs.(15))

      assert first.id == second.id
      assert second.likes_count == 15
      assert Repo.aggregate(CompetitorPostComment, :count, :id) == 1
    end

    test "comments scoped to a different post are independent rows",
         %{account: account, post: post} do
      other_post = insert_post!(account, %{post_id: "p-2", conversation_id: "conv-2"})

      {:ok, _} =
        Products.upsert_competitor_post_comment(%{
          competitor_post_id: post.id,
          platform_comment_id: "shared-id",
          text: "first parent"
        })

      {:ok, _} =
        Products.upsert_competitor_post_comment(%{
          competitor_post_id: other_post.id,
          platform_comment_id: "shared-id",
          text: "second parent"
        })

      assert Repo.aggregate(CompetitorPostComment, :count, :id) == 2
    end

    test "rejects rows missing competitor_post_id or platform_comment_id" do
      assert {:error, cs} =
               Products.upsert_competitor_post_comment(%{
                 text: "orphan"
               })

      assert errors_on(cs)[:competitor_post_id]
      assert errors_on(cs)[:platform_comment_id]
    end
  end

  describe "list_comments_for_post/1" do
    test "returns comments ordered by likes desc then posted_at asc",
         %{post: post} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, _} =
        Products.upsert_competitor_post_comment(%{
          competitor_post_id: post.id,
          platform_comment_id: "low",
          likes_count: 1,
          posted_at: now
        })

      {:ok, _} =
        Products.upsert_competitor_post_comment(%{
          competitor_post_id: post.id,
          platform_comment_id: "high",
          likes_count: 100,
          posted_at: now
        })

      [first, second] = Products.list_comments_for_post(post.id)
      assert first.platform_comment_id == "high"
      assert second.platform_comment_id == "low"
    end

    test "scopes strictly to the given post", %{account: account, post: post} do
      other_post = insert_post!(account, %{post_id: "p-3", conversation_id: "conv-3"})

      {:ok, _} =
        Products.upsert_competitor_post_comment(%{
          competitor_post_id: post.id,
          platform_comment_id: "mine"
        })

      {:ok, _} =
        Products.upsert_competitor_post_comment(%{
          competitor_post_id: other_post.id,
          platform_comment_id: "theirs"
        })

      assert [_only] = Products.list_comments_for_post(post.id)
    end
  end

  describe "CompetitorPost gains views_count + conversation_id" do
    test "casts and persists both columns", %{account: account} do
      {:ok, post} =
        Products.create_competitor_post(%{
          competitor_account_id: account.id,
          content: "with view + convo",
          views_count: 250_000,
          conversation_id: "conv-xyz"
        })

      reloaded = Repo.reload!(post)
      assert reloaded.views_count == 250_000
      assert reloaded.conversation_id == "conv-xyz"
    end

    test "defaults views_count to 0 when omitted", %{account: account} do
      {:ok, post} =
        Products.create_competitor_post(%{
          competitor_account_id: account.id,
          content: "no view col"
        })

      reloaded = Repo.reload!(post)
      assert reloaded.views_count == 0
      assert reloaded.conversation_id == nil
    end
  end

  describe "CompetitorPost has_many comments" do
    test "preloads attached comments via the association", %{post: %CompetitorPost{} = post} do
      {:ok, _} =
        Products.upsert_competitor_post_comment(%{
          competitor_post_id: post.id,
          platform_comment_id: "preload-target"
        })

      reloaded = post |> Repo.preload(:comments)
      assert [%CompetitorPostComment{platform_comment_id: "preload-target"}] = reloaded.comments
    end
  end
end
