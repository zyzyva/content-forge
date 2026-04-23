defmodule ContentForge.Jobs.PublisherMissingImageTest do
  use ContentForge.DataCase, async: false
  use Oban.Testing, repo: ContentForge.Repo

  import ExUnit.CaptureLog

  alias ContentForge.ContentGeneration
  alias ContentForge.Jobs.Publisher
  alias ContentForge.Products

  setup do
    {:ok, product} =
      Products.create_product(%{
        name: "Test Product",
        voice_profile: "professional"
      })

    %{product: product}
  end

  defp approved_social_post(product, attrs) do
    defaults = %{
      product_id: product.id,
      content: "A social post awaiting image",
      platform: "twitter",
      content_type: "post",
      angle: "educational",
      generating_model: "claude",
      status: "approved"
    }

    {:ok, draft} = ContentGeneration.create_draft(Map.merge(defaults, attrs))
    draft
  end

  describe "missing-image blocker by platform (draft_id path)" do
    for platform <- ~w(twitter linkedin reddit facebook instagram) do
      @platform platform

      test "#{platform}: draft without image_url is blocked, not published",
           %{product: product} do
        draft = approved_social_post(product, %{platform: @platform, image_url: nil})

        log =
          capture_log(fn ->
            assert {:cancel, reason} =
                     perform_job(Publisher, %{"draft_id" => draft.id})

            assert reason =~ "image"
          end)

        assert log =~ "publish blocked: missing image"

        updated = ContentGeneration.get_draft!(draft.id)
        assert updated.status == "blocked"
        assert updated.image_url == nil
      end
    end
  end

  describe "missing-image blocker (product_id + platform path)" do
    test "approved post without image_url is blocked", %{product: product} do
      draft =
        approved_social_post(product, %{platform: "twitter", image_url: nil})

      log =
        capture_log(fn ->
          assert {:cancel, reason} =
                   perform_job(Publisher, %{
                     "product_id" => product.id,
                     "platform" => "twitter"
                   })

          assert reason =~ "image"
        end)

      assert log =~ "publish blocked: missing image"

      updated = ContentGeneration.get_draft!(draft.id)
      assert updated.status == "blocked"
    end
  end

  describe "happy path (image present)" do
    test "post with image_url clears the image gate (reaches credentials check)",
         %{product: product} do
      # No credentials configured on the product, so the Publisher reaches past
      # the image gate and halts at the credentials check instead. This proves
      # the image gate passed without actually exercising the platform HTTP call.
      draft =
        approved_social_post(product, %{
          platform: "twitter",
          image_url: "https://cdn.example/img.png"
        })

      log =
        capture_log(fn ->
          assert {:cancel, "No credentials for platform"} =
                   perform_job(Publisher, %{"draft_id" => draft.id})
        end)

      refute log =~ "publish blocked: missing image"

      updated = ContentGeneration.get_draft!(draft.id)
      # Draft stays approved - the gate did not re-classify it as blocked.
      assert updated.status == "approved"
    end
  end

  describe "non-social drafts are unaffected" do
    test "blog draft without image_url is not blocked by the image gate",
         %{product: product} do
      draft =
        approved_social_post(product, %{
          platform: "blog",
          content_type: "blog",
          image_url: nil
        })

      log =
        capture_log(fn ->
          _result = perform_job(Publisher, %{"draft_id" => draft.id})
        end)

      refute log =~ "publish blocked: missing image"

      updated = ContentGeneration.get_draft!(draft.id)
      refute updated.status == "blocked"
    end
  end
end
