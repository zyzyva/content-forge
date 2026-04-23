defmodule ContentForgeWeb.Live.Dashboard.Providers.StatusLiveTest do
  use ContentForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import ExUnit.CaptureLog

  alias ContentForge.ContentGeneration
  alias ContentForge.Products
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

    # Strip every provider by default.
    Application.put_env(:content_forge, :llm, anthropic: [api_key: nil], gemini: [api_key: nil])
    Application.put_env(:content_forge, :media_forge, secret: nil)
    Application.put_env(:content_forge, :open_claw, base_url: nil, api_key: nil)
    Application.put_env(:content_forge, :apify, token: nil)

    Application.put_env(:content_forge, :twilio,
      account_sid: nil,
      auth_token: nil,
      from_number: nil
    )

    :ok
  end

  defp enable_twilio! do
    Application.put_env(:content_forge, :twilio,
      account_sid: "AC1",
      auth_token: "t",
      from_number: "+15557654321"
    )
  end

  defp enable_anthropic! do
    Application.put_env(:content_forge, :llm,
      anthropic: [api_key: "sk"],
      gemini: [api_key: nil]
    )
  end

  defp create_product! do
    {:ok, product} = Products.create_product(%{name: "P", voice_profile: "professional"})
    product
  end

  describe "provider panel" do
    test "renders a row for each of the six integrations", %{conn: conn} do
      capture_log(fn ->
        result = live(conn, ~p"/dashboard/providers")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, _view, html}}

      for id <- [:media_forge, :anthropic, :gemini, :open_claw, :apify, :twilio] do
        assert html =~ ~s|data-provider-id="#{id}"|
      end
    end

    test "all providers render with the Unavailable badge by default", %{conn: conn} do
      capture_log(fn ->
        result = live(conn, ~p"/dashboard/providers")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, _view, html}}

      for id <- [:media_forge, :anthropic, :gemini, :open_claw, :apify, :twilio] do
        assert html =~ ~s|data-provider-id="#{id}" data-provider-status="unavailable"|
      end

      assert html =~ "Unavailable"
      assert html =~ "Set ANTHROPIC_API_KEY"
      assert html =~ "Set TWILIO_ACCOUNT_SID"
    end

    test "Twilio with recent outbound sent event renders as Available",
         %{conn: conn} do
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

      capture_log(fn ->
        result = live(conn, ~p"/dashboard/providers")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, _view, html}}

      assert html =~ ~s|data-provider-id="twilio" data-provider-status="available"|
      assert html =~ "Available"
    end

    test "Twilio configured but no activity renders as Configured",
         %{conn: conn} do
      enable_twilio!()

      capture_log(fn ->
        result = live(conn, ~p"/dashboard/providers")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, _view, html}}

      assert html =~ ~s|data-provider-id="twilio" data-provider-status="configured"|
      assert html =~ "Configured"
    end

    test "Twilio with 4+ failed outbound events in last 15 min renders as Degraded",
         %{conn: conn} do
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

      capture_log(fn ->
        result = live(conn, ~p"/dashboard/providers")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, _view, html}}

      assert html =~ ~s|data-provider-id="twilio" data-provider-status="degraded"|
      assert html =~ "Degraded"
      assert html =~ "4 errors"
    end

    test "summary tiles count states accurately", %{conn: conn} do
      enable_anthropic!()
      product = create_product!()

      {:ok, _} =
        ContentGeneration.create_draft(%{
          product_id: product.id,
          content: "c",
          platform: "twitter",
          content_type: "post",
          generating_model: "anthropic:sonnet"
        })

      capture_log(fn ->
        result = live(conn, ~p"/dashboard/providers")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, _view, html}}

      # anthropic :available + 5 :unavailable.
      assert html =~ ~r|data-summary-available[^>]*>\s*1\s*<|
      assert html =~ ~r|data-summary-unavailable[^>]*>\s*5\s*<|
    end
  end

  describe "dashboard hub" do
    test "Providers card appears and summarizes counts", %{conn: conn} do
      capture_log(fn ->
        result = live(conn, ~p"/dashboard")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, _view, html}}

      assert html =~ "Providers"
      assert html =~ ~s|href="/dashboard/providers"|
      assert html =~ "need attention"
    end

    test "Hub card shows 'All integrations healthy' when nothing is unavailable or degraded",
         %{conn: conn} do
      enable_anthropic!()
      enable_twilio!()
      # Apify + OpenClaw + MF + Gemini still unavailable - so this test
      # needs to flip them to :configured too.
      Application.put_env(:content_forge, :media_forge,
        base_url: "http://mf",
        secret: "s"
      )

      Application.put_env(:content_forge, :apify, token: "t")

      Application.put_env(:content_forge, :open_claw,
        base_url: "http://oc",
        api_key: "k"
      )

      Application.put_env(:content_forge, :llm,
        anthropic: [api_key: "sk"],
        gemini: [api_key: "goog"]
      )

      capture_log(fn ->
        result = live(conn, ~p"/dashboard")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, _view, html}}

      assert html =~ "All integrations healthy"
    end
  end
end
