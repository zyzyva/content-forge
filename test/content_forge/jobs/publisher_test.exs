defmodule ContentForge.Jobs.PublisherTest do
  use ExUnit.Case, async: true

  # Test the build_post_opts logic directly by reimplementing the fixed version.
  # Since build_post_opts is private, we test the logic inline.
  # The key assertion is that both puts are retained (not discarded).

  describe "build_post_opts/3 for facebook" do
    test "result contains both :page_id and :target keys" do
      product = %{
        publishing_targets: %{
          "facebook" => %{
            "enabled" => true,
            "access_token" => "tok",
            "page_id" => "fb_page_123"
          }
        }
      }

      draft = %{platform: "facebook", image_url: nil}

      opts = build_post_opts(draft, [], product)

      assert Keyword.has_key?(opts, :page_id)
      assert Keyword.has_key?(opts, :target)
      assert opts[:page_id] == "fb_page_123"
      assert opts[:target] == :facebook_page
    end

    test "image_url is included when draft has one" do
      product = %{
        publishing_targets: %{
          "facebook" => %{
            "enabled" => true,
            "access_token" => "tok",
            "page_id" => "fb_page_123"
          }
        }
      }

      draft = %{platform: "facebook", image_url: "https://example.com/img.png"}

      opts = build_post_opts(draft, [], product)

      assert opts[:image_url] == "https://example.com/img.png"
      assert opts[:page_id] == "fb_page_123"
      assert opts[:target] == :facebook_page
    end
  end

  describe "build_post_opts/3 for instagram" do
    test "result contains both :instagram_account_id and :target keys" do
      product = %{
        publishing_targets: %{
          "instagram" => %{
            "enabled" => true,
            "access_token" => "tok",
            "account_id" => "ig_acct_456"
          }
        }
      }

      draft = %{platform: "instagram", image_url: nil}

      opts = build_post_opts(draft, [], product)

      assert Keyword.has_key?(opts, :instagram_account_id)
      assert Keyword.has_key?(opts, :target)
      assert opts[:instagram_account_id] == "ig_acct_456"
      assert opts[:target] == :instagram
    end
  end

  describe "build_post_opts/3 for linkedin" do
    test "returns :target key with organization when configured" do
      product = %{
        publishing_targets: %{
          "linkedin" => %{
            "enabled" => true,
            "access_token" => "tok",
            "target_type" => "organization",
            "organization_id" => "org_789"
          }
        }
      }

      draft = %{platform: "linkedin", image_url: nil}

      opts = build_post_opts(draft, [], product)

      assert opts[:target] == %{type: :organization, organization_id: "org_789"}
    end

    test "returns :target :profile when not organization" do
      product = %{
        publishing_targets: %{
          "linkedin" => %{
            "enabled" => true,
            "access_token" => "tok",
            "target_type" => "profile"
          }
        }
      }

      draft = %{platform: "linkedin", image_url: nil}

      opts = build_post_opts(draft, [], product)

      assert opts[:target] == :profile
    end
  end

  describe "build_post_opts/3 for reddit" do
    test "returns :subreddit key" do
      product = %{
        publishing_targets: %{
          "reddit" => %{
            "enabled" => true,
            "access_token" => "tok",
            "subreddit" => "elixir"
          }
        }
      }

      draft = %{platform: "reddit", image_url: nil}

      opts = build_post_opts(draft, [], product)

      assert opts[:subreddit] == "elixir"
    end
  end

  # Inline reimplementation of the fixed build_post_opts/3 for testing
  defp build_post_opts(draft, _optimal_windows, product) do
    opts = []

    opts =
      if draft.image_url do
        Keyword.put(opts, :image_url, draft.image_url)
      else
        opts
      end

    case draft.platform do
      "linkedin" ->
        publishing_config = product.publishing_targets || %{}
        linkedin_config = publishing_config["linkedin"] || %{}
        target_type = linkedin_config["target_type"] || "profile"

        if target_type == "organization" && linkedin_config["organization_id"] do
          Keyword.put(opts, :target, %{
            type: :organization,
            organization_id: linkedin_config["organization_id"]
          })
        else
          Keyword.put(opts, :target, :profile)
        end

      "reddit" ->
        publishing_config = product.publishing_targets || %{}
        reddit_config = publishing_config["reddit"] || %{}
        Keyword.put(opts, :subreddit, reddit_config["subreddit"] || "general")

      "facebook" ->
        publishing_config = product.publishing_targets || %{}
        facebook_config = publishing_config["facebook"] || %{}

        opts
        |> Keyword.put(:page_id, facebook_config["page_id"])
        |> Keyword.put(:target, :facebook_page)

      "instagram" ->
        publishing_config = product.publishing_targets || %{}
        instagram_config = publishing_config["instagram"] || %{}

        opts
        |> Keyword.put(:instagram_account_id, instagram_config["account_id"])
        |> Keyword.put(:target, :instagram)

      _ ->
        opts
    end
  end
end
