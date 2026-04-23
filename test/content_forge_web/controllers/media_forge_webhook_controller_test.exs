defmodule ContentForgeWeb.MediaForgeWebhookControllerTest do
  use ContentForgeWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias ContentForge.ContentGeneration
  alias ContentForge.Products
  alias ContentForge.Publishing

  @secret "webhook-test-secret"
  @config_key :media_forge

  setup %{conn: conn} do
    original = Application.get_env(:content_forge, @config_key, [])

    on_exit(fn ->
      Application.put_env(:content_forge, @config_key, original)
    end)

    Application.put_env(:content_forge, @config_key,
      base_url: "http://media-forge.test",
      secret: @secret,
      webhook_secret: @secret
    )

    {:ok, product} =
      Products.create_product(%{name: "Test Product", voice_profile: "professional"})

    %{conn: conn, product: product}
  end

  defp make_image_draft(product, job_id) do
    {:ok, draft} =
      ContentGeneration.create_draft(%{
        product_id: product.id,
        content: "awaiting image",
        platform: "twitter",
        content_type: "post",
        generating_model: "claude",
        status: "ranked",
        media_forge_job_id: job_id
      })

    draft
  end

  defp make_video_job(product, job_id, status \\ "assembled") do
    {:ok, draft} =
      ContentGeneration.create_draft(%{
        product_id: product.id,
        content: "script",
        platform: "youtube",
        content_type: "video_script",
        generating_model: "claude",
        status: "approved"
      })

    {:ok, job} =
      Publishing.create_video_job(%{
        draft_id: draft.id,
        product_id: product.id,
        status: status,
        media_forge_job_id: job_id,
        per_step_r2_keys: %{"assembled" => "video_jobs/assembled.mp4"}
      })

    job
  end

  defp sign(body, timestamp) do
    mac =
      :crypto.mac(:hmac, :sha256, @secret, "#{timestamp}.#{body}")
      |> Base.encode16(case: :lower)

    "t=#{timestamp},v1=#{mac}"
  end

  defp post_webhook(conn, payload, timestamp_override \\ nil, signature_override \\ nil) do
    body = JSON.encode!(payload)
    timestamp = timestamp_override || System.system_time(:second)

    signature =
      case signature_override do
        nil -> sign(body, timestamp)
        :none -> nil
        override -> override
      end

    conn =
      conn
      |> Plug.Conn.put_req_header("content-type", "application/json")

    conn =
      if signature do
        Plug.Conn.put_req_header(conn, "x-mediaforge-signature", signature)
      else
        conn
      end

    post(conn, "/webhooks/media_forge", body)
  end

  describe "image draft resolution" do
    test "job.done updates image_url and returns 200", %{conn: conn, product: product} do
      draft = make_image_draft(product, "mf-img-done-1")

      payload = %{
        "event" => "job.done",
        "job" => %{"id" => "mf-img-done-1"},
        "result" => %{"image_url" => "https://cdn.example/img.png"}
      }

      conn = post_webhook(conn, payload)

      assert conn.status == 200

      updated = ContentGeneration.get_draft!(draft.id)
      assert updated.image_url == "https://cdn.example/img.png"
      assert updated.status == "ranked"
    end

    test "job.failed marks the draft blocked with an error note",
         %{conn: conn, product: product} do
      draft = make_image_draft(product, "mf-img-fail-1")

      payload = %{
        "event" => "job.failed",
        "job" => %{"id" => "mf-img-fail-1"},
        "error" => "provider quota exceeded"
      }

      conn = post_webhook(conn, payload)

      assert conn.status == 200

      updated = ContentGeneration.get_draft!(draft.id)
      assert updated.status == "blocked"
      assert updated.error == "provider quota exceeded"
      assert updated.image_url == nil
    end
  end

  describe "video job resolution" do
    test "job.done records the R2 key and transitions to encoded, returns 200",
         %{conn: conn, product: product} do
      job = make_video_job(product, "mf-vid-done-1")

      payload = %{
        "event" => "job.done",
        "job" => %{"id" => "mf-vid-done-1"},
        "result" => %{"output_r2_key" => "videos/encoded-abc.mp4"}
      }

      conn = post_webhook(conn, payload)

      assert conn.status == 200

      updated = Publishing.get_video_job(job.id)
      assert updated.status == "encoded"
      assert updated.per_step_r2_keys["final"] == "videos/encoded-abc.mp4"
    end

    test "job.failed transitions to failed with error recorded",
         %{conn: conn, product: product} do
      job = make_video_job(product, "mf-vid-fail-1")

      payload = %{
        "event" => "job.failed",
        "job" => %{"id" => "mf-vid-fail-1"},
        "error" => "render crashed"
      }

      conn = post_webhook(conn, payload)

      assert conn.status == 200

      updated = Publishing.get_video_job(job.id)
      assert updated.status == "failed"
      assert updated.error == "render crashed"
    end
  end

  describe "idempotency" do
    test "repeat webhook for an already-terminal image draft is a no-op 200",
         %{conn: conn, product: product} do
      draft = make_image_draft(product, "mf-img-idempotent")

      {:ok, draft} =
        ContentGeneration.update_draft(draft, %{image_url: "https://cdn.example/existing.png"})

      payload = %{
        "event" => "job.done",
        "job" => %{"id" => "mf-img-idempotent"},
        "result" => %{"image_url" => "https://cdn.example/should-not-overwrite.png"}
      }

      conn = post_webhook(conn, payload)
      assert conn.status == 200

      after_call = ContentGeneration.get_draft!(draft.id)
      # Unchanged
      assert after_call.image_url == "https://cdn.example/existing.png"
      assert after_call.updated_at == draft.updated_at
    end

    test "repeat webhook for an already-encoded video job is a no-op 200",
         %{conn: conn, product: product} do
      job = make_video_job(product, "mf-vid-idempotent", "encoded")

      payload = %{
        "event" => "job.done",
        "job" => %{"id" => "mf-vid-idempotent"},
        "result" => %{"output_r2_key" => "videos/should-not-overwrite.mp4"}
      }

      conn = post_webhook(conn, payload)
      assert conn.status == 200

      after_call = Publishing.get_video_job(job.id)
      # Unchanged
      assert after_call.status == "encoded"
      refute after_call.per_step_r2_keys["final"] == "videos/should-not-overwrite.mp4"
    end
  end

  describe "rejection paths" do
    test "stale timestamp outside the 300-second window returns 400",
         %{conn: conn, product: product} do
      _draft = make_image_draft(product, "mf-stale")

      payload = %{
        "event" => "job.done",
        "job" => %{"id" => "mf-stale"},
        "result" => %{"image_url" => "https://cdn.example/x.png"}
      }

      stale_ts = System.system_time(:second) - 301

      log =
        capture_log(fn ->
          conn = post_webhook(conn, payload, stale_ts)
          send(self(), {:conn, conn})
        end)

      assert_received {:conn, conn}
      assert conn.status == 400
      assert conn.resp_body =~ "stale"
      assert log =~ "stale request"
    end

    test "invalid signature returns 401", %{conn: conn, product: product} do
      _draft = make_image_draft(product, "mf-bad-sig")

      payload = %{
        "event" => "job.done",
        "job" => %{"id" => "mf-bad-sig"},
        "result" => %{"image_url" => "https://cdn.example/x.png"}
      }

      ts = System.system_time(:second)
      bad_sig = "t=#{ts},v1=000000000000000000000000000000000000000000000000000000000000dead"

      log =
        capture_log(fn ->
          conn = post_webhook(conn, payload, nil, bad_sig)
          send(self(), {:conn, conn})
        end)

      assert_received {:conn, conn}
      assert conn.status == 401
      assert conn.resp_body =~ "invalid"
      assert log =~ "invalid signature"
    end

    test "missing signature header returns 401", %{conn: conn, product: product} do
      _draft = make_image_draft(product, "mf-no-sig")

      payload = %{
        "event" => "job.done",
        "job" => %{"id" => "mf-no-sig"},
        "result" => %{"image_url" => "https://cdn.example/x.png"}
      }

      log =
        capture_log(fn ->
          conn = post_webhook(conn, payload, nil, :none)
          send(self(), {:conn, conn})
        end)

      assert_received {:conn, conn}
      assert conn.status == 401
      assert log =~ "missing signature"
    end

    test "unknown Media Forge job id returns 404", %{conn: conn} do
      payload = %{
        "event" => "job.done",
        "job" => %{"id" => "mf-does-not-exist"},
        "result" => %{"image_url" => "https://cdn.example/x.png"}
      }

      log =
        capture_log(fn ->
          conn = post_webhook(conn, payload)
          send(self(), {:conn, conn})
        end)

      assert_received {:conn, conn}
      assert conn.status == 404
      assert log =~ "unknown job id"
    end

    test "malformed payload without event returns 400", %{conn: conn} do
      payload = %{"job" => %{"id" => "mf-malformed"}}

      log =
        capture_log(fn ->
          conn = post_webhook(conn, payload)
          send(self(), {:conn, conn})
        end)

      assert_received {:conn, conn}
      assert conn.status == 400
      assert log =~ "malformed payload"
    end
  end
end
