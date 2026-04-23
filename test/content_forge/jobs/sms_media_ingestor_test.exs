defmodule ContentForge.Jobs.SmsMediaIngestorTest do
  use ContentForge.DataCase, async: false
  use Oban.Testing, repo: ContentForge.Repo

  import ExUnit.CaptureLog

  alias ContentForge.Jobs.AssetImageProcessor
  alias ContentForge.Jobs.AssetVideoProcessor
  alias ContentForge.Jobs.SmsMediaIngestor
  alias ContentForge.ProductAssets
  alias ContentForge.Products
  alias ContentForge.Sms

  @twilio_key :twilio
  @twilio_stub ContentForge.Twilio
  @storage_key :asset_storage_impl

  defmodule StorageStub do
    @moduledoc false

    def put_object(key, body, _opts \\ []) do
      Agent.update(__MODULE__.Log, fn log -> log ++ [{key, body}] end)
      {:ok, key}
    end

    def started? do
      Process.whereis(__MODULE__.Log) != nil
    end

    def start do
      {:ok, _} = Agent.start_link(fn -> [] end, name: __MODULE__.Log)
      :ok
    end

    def log, do: Agent.get(__MODULE__.Log, & &1)

    def reset do
      Agent.update(__MODULE__.Log, fn _ -> [] end)
    end
  end

  setup do
    twilio_original = Application.get_env(:content_forge, @twilio_key, [])
    storage_original = Application.get_env(:content_forge, @storage_key)

    on_exit(fn ->
      Application.put_env(:content_forge, @twilio_key, twilio_original)
      restore_storage(storage_original)
    end)

    Application.put_env(:content_forge, @twilio_key,
      base_url: "http://twilio.test",
      account_sid: "ACtest12345",
      auth_token: "twilio-auth-token",
      from_number: "+15557654321",
      default_messaging_service_sid: nil,
      req_options: [plug: {Req.Test, @twilio_stub}]
    )

    Application.put_env(:content_forge, @storage_key, StorageStub)

    unless StorageStub.started?(), do: StorageStub.start()
    StorageStub.reset()

    {:ok, product} =
      Products.create_product(%{name: "MMS Ingest Product", voice_profile: "professional"})

    {:ok, _phone} =
      Sms.create_phone(%{
        product_id: product.id,
        phone_number: "+15551112222",
        role: "submitter"
      })

    %{product: product}
  end

  defp restore_storage(nil), do: Application.delete_env(:content_forge, @storage_key)
  defp restore_storage(val), do: Application.put_env(:content_forge, @storage_key, val)

  defp make_inbound_event!(product, media_urls) do
    {:ok, event} =
      Sms.record_event(%{
        product_id: product.id,
        phone_number: "+15551112222",
        direction: "inbound",
        status: "received",
        body: "picture",
        media_urls: media_urls,
        twilio_sid: "SMmedia_#{System.unique_integer([:positive])}"
      })

    event
  end

  defp jpeg_bytes, do: "\xFF\xD8\xFF\xE0\x00\x10JFIF" <> :crypto.strong_rand_bytes(64)
  defp mp4_bytes, do: "\x00\x00\x00\x20ftyp" <> :crypto.strong_rand_bytes(64)

  defp run(event_id) do
    perform_job(SmsMediaIngestor, %{"event_id" => event_id})
  end

  describe "happy path (image)" do
    test "downloads the media, uploads to R2, creates a ProductAsset, enqueues AssetImageProcessor",
         %{product: product} do
      event = make_inbound_event!(product, ["http://twilio.test/media/MExxx"])
      bytes = jpeg_bytes()

      Req.Test.stub(@twilio_stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "image/jpeg")
        |> Plug.Conn.resp(200, bytes)
      end)

      assert {:ok, created} = run(event.id)
      assert created == 1

      [asset] = ProductAssets.list_assets(product.id)
      assert asset.media_type == "image"
      assert asset.mime_type == "image/jpeg"
      assert asset.uploader == "+15551112222"
      assert asset.byte_size == byte_size(bytes)
      assert String.ends_with?(asset.filename, ".jpg")
      assert String.contains?(asset.storage_key, "products/#{product.id}/assets/")
      assert String.contains?(asset.storage_key, "sms_#{event.id}_0")

      # Storage got the bytes.
      [{key, body}] = StorageStub.log()
      assert key == asset.storage_key
      assert body == bytes

      assert_enqueued(
        worker: AssetImageProcessor,
        args: %{"asset_id" => asset.id}
      )
    end
  end

  describe "happy path (video)" do
    test "enqueues AssetVideoProcessor for video media", %{product: product} do
      event = make_inbound_event!(product, ["http://twilio.test/media/MEvideo"])
      bytes = mp4_bytes()

      Req.Test.stub(@twilio_stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "video/mp4")
        |> Plug.Conn.resp(200, bytes)
      end)

      assert {:ok, 1} = run(event.id)

      [asset] = ProductAssets.list_assets(product.id)
      assert asset.media_type == "video"
      assert asset.mime_type == "video/mp4"
      assert String.ends_with?(asset.filename, ".mp4")

      assert_enqueued(
        worker: AssetVideoProcessor,
        args: %{"asset_id" => asset.id}
      )
    end
  end

  describe "multiple media urls" do
    test "creates one ProductAsset per url and enqueues per media_type",
         %{product: product} do
      event =
        make_inbound_event!(product, [
          "http://twilio.test/media/ME1",
          "http://twilio.test/media/ME2"
        ])

      Req.Test.stub(@twilio_stub, fn conn ->
        {ct, body} =
          case conn.request_path do
            "/media/ME1" -> {"image/jpeg", jpeg_bytes()}
            "/media/ME2" -> {"video/mp4", mp4_bytes()}
          end

        conn
        |> Plug.Conn.put_resp_header("content-type", ct)
        |> Plug.Conn.resp(200, body)
      end)

      assert {:ok, 2} = run(event.id)

      assets = ProductAssets.list_assets(product.id)
      assert length(assets) == 2

      types = assets |> Enum.map(& &1.media_type) |> Enum.sort()
      assert types == ["image", "video"]
    end
  end

  describe "unsupported MIME" do
    test "records an audit row and skips without creating an asset", %{product: product} do
      event = make_inbound_event!(product, ["http://twilio.test/media/MEtxt"])

      Req.Test.stub(@twilio_stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "text/plain")
        |> Plug.Conn.resp(200, "hello")
      end)

      log =
        capture_log(fn ->
          assert {:ok, 0} = run(event.id)
        end)

      assert log =~ "unsupported"
      assert [] = ProductAssets.list_assets(product.id)

      rejected =
        Sms.list_events(event.product_id,
          phone_number: event.phone_number,
          status: "unsupported_media"
        )

      assert length(rejected) == 1
    end

    test "continues to the next URL after an unsupported MIME",
         %{product: product} do
      event =
        make_inbound_event!(product, [
          "http://twilio.test/media/MEbad",
          "http://twilio.test/media/MEgood"
        ])

      Req.Test.stub(@twilio_stub, fn conn ->
        case conn.request_path do
          "/media/MEbad" ->
            conn
            |> Plug.Conn.put_resp_header("content-type", "application/zip")
            |> Plug.Conn.resp(200, "not media")

          "/media/MEgood" ->
            conn
            |> Plug.Conn.put_resp_header("content-type", "image/jpeg")
            |> Plug.Conn.resp(200, jpeg_bytes())
        end
      end)

      capture_log(fn ->
        assert {:ok, 1} = run(event.id)
      end)

      assets = ProductAssets.list_assets(product.id)
      assert length(assets) == 1
      assert hd(assets).media_type == "image"
    end
  end

  describe "Twilio :not_configured" do
    test "records a failed-ingestion audit row and returns {:ok, :skipped}",
         %{product: product} do
      Application.put_env(:content_forge, @twilio_key,
        base_url: "http://twilio.test",
        account_sid: nil,
        auth_token: nil,
        from_number: nil,
        default_messaging_service_sid: nil,
        req_options: [plug: {Req.Test, @twilio_stub}]
      )

      event = make_inbound_event!(product, ["http://twilio.test/media/MEany"])

      test_pid = self()

      Req.Test.stub(@twilio_stub, fn _conn ->
        send(test_pid, :unexpected_http)
        raise "no HTTP expected when Twilio is not configured"
      end)

      log =
        capture_log(fn ->
          assert {:ok, :skipped} = run(event.id)
        end)

      refute_received :unexpected_http
      assert log =~ "Twilio unavailable"

      failed =
        Sms.list_events(product.id, status: "unsupported_media") ++
          Sms.list_events(product.id, status: "failed")

      refute failed == []
      assert [] = ProductAssets.list_assets(product.id)
    end
  end

  describe "permanent download error" do
    test "records a failed audit row and cancels", %{product: product} do
      event = make_inbound_event!(product, ["http://twilio.test/media/MEforbidden"])

      Req.Test.stub(@twilio_stub, fn conn ->
        conn
        |> Plug.Conn.put_status(403)
        |> Req.Test.json(%{"message" => "forbidden"})
      end)

      log =
        capture_log(fn ->
          assert {:cancel, reason} = run(event.id)
          assert reason =~ "HTTP 403"
        end)

      assert log =~ "permanent"
      assert [] = ProductAssets.list_assets(product.id)
    end
  end

  describe "transient download error" do
    test "returns {:error, _} for Oban retry", %{product: product} do
      event = make_inbound_event!(product, ["http://twilio.test/media/MEtrans"])

      Req.Test.stub(@twilio_stub, fn conn ->
        conn
        |> Plug.Conn.put_status(503)
        |> Req.Test.json(%{"message" => "overloaded"})
      end)

      log =
        capture_log(fn ->
          assert {:error, {:transient, 503, _}} = run(event.id)
        end)

      assert log =~ "transient"
      assert [] = ProductAssets.list_assets(product.id)
    end
  end

  describe "bad input" do
    test "unknown event id cancels", %{product: _product} do
      log =
        capture_log(fn ->
          assert {:cancel, reason} = run("00000000-0000-0000-0000-000000000000")
          assert reason =~ "event"
        end)

      assert log =~ "SmsMediaIngestor"
    end

    test "event with empty media_urls returns {:ok, 0}", %{product: product} do
      event = make_inbound_event!(product, [])

      test_pid = self()

      Req.Test.stub(@twilio_stub, fn _conn ->
        send(test_pid, :unexpected_http)
        raise "no HTTP expected when media_urls is empty"
      end)

      assert {:ok, 0} = run(event.id)
      refute_received :unexpected_http
      assert [] = ProductAssets.list_assets(product.id)
    end

    test "outbound event cancels", %{product: product} do
      {:ok, outbound} =
        Sms.record_event(%{
          product_id: product.id,
          phone_number: "+15551112222",
          direction: "outbound",
          status: "sent",
          body: "noise"
        })

      capture_log(fn ->
        assert {:cancel, reason} = run(outbound.id)
        assert reason =~ "inbound"
      end)
    end
  end
end
