defmodule ContentForge.ProvidersTest do
  use ContentForge.DataCase, async: false

  alias ContentForge.ContentGeneration
  alias ContentForge.ProductAssets
  alias ContentForge.Products
  alias ContentForge.Providers
  alias ContentForge.Sms

  setup do
    original = %{
      llm: Application.get_env(:content_forge, :llm, []),
      media_forge: Application.get_env(:content_forge, :media_forge, []),
      open_claw: Application.get_env(:content_forge, :open_claw, []),
      apify: Application.get_env(:content_forge, :apify, []),
      twilio: Application.get_env(:content_forge, :twilio, [])
    }

    on_exit(fn ->
      Enum.each(original, fn {k, v} ->
        Application.put_env(:content_forge, k, v)
      end)
    end)

    # Strip every provider by default. Individual tests enable the ones
    # they want.
    Application.put_env(:content_forge, :llm,
      anthropic: [api_key: nil],
      gemini: [api_key: nil]
    )

    Application.put_env(:content_forge, :media_forge, secret: nil)
    Application.put_env(:content_forge, :open_claw, base_url: nil, api_key: nil)
    Application.put_env(:content_forge, :apify, token: nil)

    Application.put_env(:content_forge, :twilio,
      account_sid: nil,
      auth_token: nil,
      from_number: nil,
      default_messaging_service_sid: nil
    )

    :ok
  end

  defp enable_twilio! do
    Application.put_env(:content_forge, :twilio,
      account_sid: "AC1",
      auth_token: "t",
      from_number: "+15557654321",
      default_messaging_service_sid: nil
    )
  end

  defp enable_media_forge! do
    Application.put_env(:content_forge, :media_forge,
      base_url: "http://mf",
      secret: "s"
    )
  end

  defp enable_anthropic! do
    Application.put_env(:content_forge, :llm,
      anthropic: [api_key: "sk-test"],
      gemini: [api_key: nil]
    )
  end

  defp enable_gemini! do
    Application.put_env(:content_forge, :llm,
      anthropic: [api_key: nil],
      gemini: [api_key: "goog-test"]
    )
  end

  defp enable_open_claw! do
    Application.put_env(:content_forge, :open_claw,
      base_url: "http://oc.test",
      api_key: "oc-key"
    )
  end

  defp enable_apify!, do: Application.put_env(:content_forge, :apify, token: "apify-tok")

  defp row(rows, id), do: Enum.find(rows, &(&1.id == id))

  defp create_product!(name \\ "P") do
    {:ok, product} = Products.create_product(%{name: name, voice_profile: "professional"})
    product
  end

  describe "default: every provider unavailable" do
    test "returns all six rows as :unavailable with a note" do
      rows = Providers.list_provider_statuses()

      assert length(rows) == 6

      Enum.each(
        [:media_forge, :anthropic, :gemini, :open_claw, :apify, :twilio],
        fn id ->
          r = row(rows, id)
          assert r.status == :unavailable, "expected #{id} :unavailable, got #{r.status}"
          assert is_binary(r.note)
        end
      )
    end

    test "summary/0 counts all as unavailable" do
      summary = Providers.summary()
      assert summary.unavailable == 6
      assert summary.available == 0
      assert summary.configured == 0
      assert summary.degraded == 0
    end
  end

  describe ":configured - credentials but no recent activity" do
    test "Twilio with only config returns :configured", _ctx do
      enable_twilio!()

      assert row(Providers.list_provider_statuses(), :twilio).status == :configured
    end

    test "Anthropic with only config returns :configured" do
      enable_anthropic!()

      assert row(Providers.list_provider_statuses(), :anthropic).status == :configured
    end

    test "Gemini with only config returns :configured" do
      enable_gemini!()

      assert row(Providers.list_provider_statuses(), :gemini).status == :configured
    end

    test "Media Forge with only config returns :configured" do
      enable_media_forge!()

      assert row(Providers.list_provider_statuses(), :media_forge).status == :configured
    end

    test "OpenClaw with only config returns :configured" do
      enable_open_claw!()

      assert row(Providers.list_provider_statuses(), :open_claw).status == :configured
    end

    test "Apify with only config returns :configured" do
      enable_apify!()

      assert row(Providers.list_provider_statuses(), :apify).status == :configured
    end
  end

  describe ":available - credentials + recent successful use" do
    test "Twilio with recent outbound sent event is :available" do
      enable_twilio!()
      product = create_product!()

      {:ok, _} =
        Sms.record_event(%{
          product_id: product.id,
          phone_number: "+15551112222",
          direction: "outbound",
          status: "sent",
          body: "hi"
        })

      r = row(Providers.list_provider_statuses(), :twilio)
      assert r.status == :available
      assert %DateTime{} = r.last_success_at
    end

    test "Anthropic with recent Draft (anthropic:...) is :available" do
      enable_anthropic!()
      product = create_product!()

      {:ok, _} =
        ContentGeneration.create_draft(%{
          product_id: product.id,
          content: "c",
          platform: "twitter",
          content_type: "post",
          generating_model: "anthropic:claude-sonnet-4-6-20250929"
        })

      r = row(Providers.list_provider_statuses(), :anthropic)
      assert r.status == :available
      assert %DateTime{} = r.last_success_at
    end

    test "Media Forge with recent processed ProductAsset is :available" do
      enable_media_forge!()
      product = create_product!()

      {:ok, asset} =
        ProductAssets.create_asset(%{
          product_id: product.id,
          storage_key: "products/#{product.id}/assets/hero.jpg",
          filename: "hero.jpg",
          mime_type: "image/jpeg",
          media_type: "image",
          byte_size: 1024,
          uploaded_at: DateTime.utc_now()
        })

      {:ok, _} = ProductAssets.mark_processed(asset, %{width: 1200, height: 800})

      r = row(Providers.list_provider_statuses(), :media_forge)
      assert r.status == :available
      assert %DateTime{} = r.last_success_at
    end
  end

  describe ":degraded - more than 3 transient errors in last 15 minutes" do
    test "Twilio with 4 failed outbound events in window flips to :degraded" do
      enable_twilio!()
      product = create_product!()

      Enum.each(1..4, fn i ->
        {:ok, _} =
          Sms.record_event(%{
            product_id: product.id,
            phone_number: "+15551112222",
            direction: "outbound",
            status: "failed",
            body: "fail #{i}"
          })
      end)

      r = row(Providers.list_provider_statuses(), :twilio)
      assert r.status == :degraded
      assert %DateTime{} = r.last_error_at
      assert r.note =~ "4 errors"
    end

    test "Twilio with exactly 3 failed events stays :configured (threshold is strictly >3)" do
      enable_twilio!()
      product = create_product!()

      Enum.each(1..3, fn i ->
        {:ok, _} =
          Sms.record_event(%{
            product_id: product.id,
            phone_number: "+15551112222",
            direction: "outbound",
            status: "failed",
            body: "fail #{i}"
          })
      end)

      r = row(Providers.list_provider_statuses(), :twilio)
      refute r.status == :degraded
    end
  end

  describe "summary/0 counts by state" do
    test "mixes all four states correctly" do
      enable_twilio!()
      enable_anthropic!()

      product = create_product!()

      # Anthropic -> :available via a recent Draft.
      {:ok, _} =
        ContentGeneration.create_draft(%{
          product_id: product.id,
          content: "c",
          platform: "twitter",
          content_type: "post",
          generating_model: "anthropic:sonnet"
        })

      # Twilio -> :degraded via 4 failed events.
      Enum.each(1..4, fn i ->
        {:ok, _} =
          Sms.record_event(%{
            product_id: product.id,
            phone_number: "+15551112222",
            direction: "outbound",
            status: "failed",
            body: "fail #{i}"
          })
      end)

      summary = Providers.summary()

      # anthropic :available + twilio :degraded + gemini :unavailable + MF
      # :unavailable + OpenClaw :unavailable + Apify :unavailable
      assert summary.available == 1
      assert summary.degraded == 1
      assert summary.unavailable == 4
      assert summary.configured == 0
    end
  end
end
