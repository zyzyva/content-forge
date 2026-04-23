defmodule ContentForgeWeb.OpenClawToolControllerTest do
  @moduledoc """
  Phase 16.1 coverage for the OpenClaw tool HTTP surface.

  The controller authenticates via `X-OpenClaw-Tool-Secret`
  (fail-closed on missing / mismatched / unconfigured secret)
  and dispatches to `ContentForge.OpenClawTools.<Tool>.call/2`
  by pattern matching on the URL's tool_name.
  """
  use ContentForgeWeb.ConnCase, async: false

  alias ContentForge.ContentGeneration.Draft
  alias ContentForge.Operators
  alias ContentForge.ProductAssets
  alias ContentForge.Products
  alias ContentForge.Repo
  alias ContentForge.Sms

  @secret "openclaw-tool-secret-test-value"

  setup %{conn: conn} do
    original = Application.get_env(:content_forge, :open_claw_tool_secret)
    original_storage = Application.get_env(:content_forge, :asset_storage_impl)

    Application.put_env(:content_forge, :open_claw_tool_secret, @secret)
    Application.put_env(:content_forge, :asset_storage_impl, __MODULE__.StorageStub)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:content_forge, :open_claw_tool_secret)
      else
        Application.put_env(:content_forge, :open_claw_tool_secret, original)
      end

      if is_nil(original_storage) do
        Application.delete_env(:content_forge, :asset_storage_impl)
      else
        Application.put_env(:content_forge, :asset_storage_impl, original_storage)
      end
    end)

    json_conn = put_req_header(conn, "accept", "application/json")
    %{conn: json_conn}
  end

  defmodule StorageStub do
    @moduledoc false
    def presigned_put_url(storage_key, _content_type, _opts) do
      {:ok, "https://stub.example/put/" <> storage_key <> "?sig=abc"}
    end
  end

  describe "auth" do
    test "401 when the secret header is missing", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/openclaw/tools/create_upload_link", %{})
      assert json_response(conn, 401) == %{"errors" => %{"detail" => "Unauthorized"}}
    end

    test "401 when the secret header is wrong", %{conn: conn} do
      conn =
        conn
        |> put_req_header("x-openclaw-tool-secret", "wrong-secret")
        |> post(~p"/api/v1/openclaw/tools/create_upload_link", %{})

      assert json_response(conn, 401) == %{"errors" => %{"detail" => "Unauthorized"}}
    end

    test "401 when the server-side secret is not configured", %{conn: conn} do
      Application.delete_env(:content_forge, :open_claw_tool_secret)

      conn =
        conn
        |> put_req_header("x-openclaw-tool-secret", @secret)
        |> post(~p"/api/v1/openclaw/tools/create_upload_link", %{})

      assert json_response(conn, 401) == %{"errors" => %{"detail" => "Unauthorized"}}
    end
  end

  describe "dispatch" do
    test "dispatches to CreateUploadLink and returns a presigned URL",
         %{conn: conn} do
      {:ok, product} =
        Products.create_product(%{name: "Acme Widgets Inc", voice_profile: "professional"})

      {:ok, _} =
        Operators.create_identity(%{
          product_id: product.id,
          identity: "cli:ops",
          role: "submitter"
        })

      body = %{
        "session_id" => "test-session",
        "channel" => "cli",
        "sender_identity" => "cli:ops",
        "params" => %{"product" => "Acme"}
      }

      conn =
        conn
        |> put_req_header("x-openclaw-tool-secret", @secret)
        |> post(~p"/api/v1/openclaw/tools/create_upload_link", body)

      assert %{
               "status" => "ok",
               "result" => %{
                 "url" => url,
                 "storage_key" => storage_key,
                 "product_id" => product_id,
                 "product_name" => "Acme Widgets Inc",
                 "expires_in_seconds" => 900
               }
             } = json_response(conn, 200)

      assert String.starts_with?(url, "https://stub.example/put/")
      assert product_id == product.id
      assert String.starts_with?(storage_key, "products/#{product.id}/assets/")
    end

    test "404 on an unknown tool name", %{conn: conn} do
      body = %{"params" => %{}}

      conn =
        conn
        |> put_req_header("x-openclaw-tool-secret", @secret)
        |> post(~p"/api/v1/openclaw/tools/wat_is_this", body)

      assert %{"status" => "error", "error" => "unknown_tool", "tool_name" => "wat_is_this"} =
               json_response(conn, 404)
    end

    test "422 on classified tool error (product not found)", %{conn: conn} do
      body = %{"params" => %{"product" => "does-not-exist"}}

      conn =
        conn
        |> put_req_header("x-openclaw-tool-secret", @secret)
        |> post(~p"/api/v1/openclaw/tools/create_upload_link", body)

      assert %{"status" => "error", "error" => "product_not_found"} =
               json_response(conn, 422)
    end

    test "resolves product via the SMS session when no product param is supplied",
         %{conn: conn} do
      {:ok, product} =
        Products.create_product(%{name: "SMS Pilot", voice_profile: "warm"})

      {:ok, _} =
        Sms.create_phone(%{
          product_id: product.id,
          phone_number: "+15551112222",
          role: "owner",
          active: true
        })

      body = %{
        "session_id" => "sms-session",
        "channel" => "sms",
        "sender_identity" => "+15551112222",
        "params" => %{}
      }

      conn =
        conn
        |> put_req_header("x-openclaw-tool-secret", @secret)
        |> post(~p"/api/v1/openclaw/tools/create_upload_link", body)

      assert %{
               "status" => "ok",
               "result" => %{"product_id" => product_id, "product_name" => "SMS Pilot"}
             } = json_response(conn, 200)

      assert product_id == product.id
    end

    test "422 on ambiguous product match", %{conn: conn} do
      {:ok, _} =
        Products.create_product(%{name: "Ambiguous One", voice_profile: "professional"})

      {:ok, _} =
        Products.create_product(%{name: "Ambiguous Two", voice_profile: "professional"})

      body = %{"params" => %{"product" => "Ambiguous"}}

      conn =
        conn
        |> put_req_header("x-openclaw-tool-secret", @secret)
        |> post(~p"/api/v1/openclaw/tools/create_upload_link", body)

      assert %{"status" => "error", "error" => "ambiguous_product"} =
               json_response(conn, 422)
    end
  end

  describe "16.2 read-only tools" do
    setup do
      {:ok, product} =
        Products.create_product(%{name: "Readonly Land", voice_profile: "warm"})

      %{product: product}
    end

    test "dispatches list_recent_assets and serializes each asset", %{
      conn: conn,
      product: product
    } do
      {:ok, _asset} =
        ProductAssets.create_asset(%{
          product_id: product.id,
          storage_key: "products/#{product.id}/assets/alpha",
          media_type: "image",
          filename: "alpha.jpg",
          mime_type: "image/jpeg",
          byte_size: 2048,
          uploaded_at: DateTime.utc_now()
        })

      body = %{"params" => %{"product" => product.id}}

      conn =
        conn
        |> put_req_header("x-openclaw-tool-secret", @secret)
        |> post(~p"/api/v1/openclaw/tools/list_recent_assets", body)

      assert %{
               "status" => "ok",
               "result" => %{
                 "product_id" => pid,
                 "product_name" => "Readonly Land",
                 "count" => 1,
                 "assets" => [
                   %{
                     "filename" => "alpha.jpg",
                     "media_type" => "image",
                     "status" => "pending",
                     "mime_type" => "image/jpeg",
                     "byte_size" => 2048,
                     "uploaded_at" => uploaded_at
                   }
                 ]
               }
             } = json_response(conn, 200)

      assert pid == product.id
      assert is_binary(uploaded_at)
    end

    test "dispatches draft_status and returns 422 for not-found", %{
      conn: conn,
      product: product
    } do
      body = %{
        "params" => %{
          "product" => product.id,
          "draft_id" => Ecto.UUID.generate()
        }
      }

      conn =
        conn
        |> put_req_header("x-openclaw-tool-secret", @secret)
        |> post(~p"/api/v1/openclaw/tools/draft_status", body)

      assert %{"status" => "error", "error" => "not_found"} =
               json_response(conn, 422)
    end

    test "dispatches upcoming_schedule and returns a JSON draft list", %{
      conn: conn,
      product: product
    } do
      {:ok, draft} =
        %Draft{}
        |> Draft.changeset(%{
          product_id: product.id,
          content: "Approved body",
          platform: "linkedin",
          content_type: "post",
          generating_model: "stub",
          status: "approved",
          angle: "how_to"
        })
        |> Repo.insert()

      body = %{"params" => %{"product" => product.id}}

      conn =
        conn
        |> put_req_header("x-openclaw-tool-secret", @secret)
        |> post(~p"/api/v1/openclaw/tools/upcoming_schedule", body)

      assert %{
               "status" => "ok",
               "result" => %{
                 "count" => 1,
                 "drafts" => [
                   %{"id" => id, "platform" => "linkedin", "angle" => "how_to"}
                 ]
               }
             } = json_response(conn, 200)

      assert id == draft.id
    end

    test "dispatches competitor_intel_summary and serializes arrays", %{
      conn: conn,
      product: product
    } do
      {:ok, _} =
        Products.create_competitor_intel(%{
          product_id: product.id,
          summary: "state of the competition",
          trending_topics: ["topic-a"],
          winning_formats: ["format-a"],
          effective_hooks: ["hook-a"],
          source_count: 12
        })

      body = %{"params" => %{"product" => product.id}}

      conn =
        conn
        |> put_req_header("x-openclaw-tool-secret", @secret)
        |> post(~p"/api/v1/openclaw/tools/competitor_intel_summary", body)

      assert %{
               "status" => "ok",
               "result" => %{
                 "summary" => "state of the competition",
                 "trending_topics" => ["topic-a"],
                 "winning_formats" => ["format-a"],
                 "effective_hooks" => ["hook-a"],
                 "source_post_count" => 12,
                 "generated_at" => generated_at
               }
             } = json_response(conn, 200)

      assert is_binary(generated_at)
    end

    test "competitor_intel_summary returns 422 not_found when no intel row exists",
         %{conn: conn, product: product} do
      body = %{"params" => %{"product" => product.id}}

      conn =
        conn
        |> put_req_header("x-openclaw-tool-secret", @secret)
        |> post(~p"/api/v1/openclaw/tools/competitor_intel_summary", body)

      assert %{"status" => "error", "error" => "not_found"} =
               json_response(conn, 422)
    end
  end

  describe "16.3c light-write tools" do
    setup do
      {:ok, product} =
        Products.create_product(%{name: "Writeland", voice_profile: "warm"})

      {:ok, _} =
        Operators.create_identity(%{
          product_id: product.id,
          identity: "cli:writer",
          role: "submitter"
        })

      %{product: product}
    end

    test "dispatches create_asset_bundle through the full HTTP pipeline",
         %{conn: conn, product: product} do
      body = %{
        "channel" => "cli",
        "sender_identity" => "cli:writer",
        "params" => %{"product" => product.id, "name" => "Autumn campaign"}
      }

      conn =
        conn
        |> put_req_header("x-openclaw-tool-secret", @secret)
        |> post(~p"/api/v1/openclaw/tools/create_asset_bundle", body)

      assert %{
               "status" => "ok",
               "result" => %{
                 "name" => "Autumn campaign",
                 "status" => "active",
                 "bundle_id" => bundle_id,
                 "product_id" => pid,
                 "created_at" => created_at
               }
             } = json_response(conn, 200)

      assert pid == product.id
      assert is_binary(bundle_id)
      assert is_binary(created_at)
    end

    test "create_asset_bundle 422 on forbidden (no OperatorIdentity)",
         %{conn: conn, product: product} do
      body = %{
        "channel" => "cli",
        "sender_identity" => "cli:stranger",
        "params" => %{"product" => product.id, "name" => "Nope"}
      }

      conn =
        conn
        |> put_req_header("x-openclaw-tool-secret", @secret)
        |> post(~p"/api/v1/openclaw/tools/create_asset_bundle", body)

      assert %{"status" => "error", "error" => "forbidden"} =
               json_response(conn, 422)
    end

    test "dispatches add_tag_to_asset through the full HTTP pipeline",
         %{conn: conn, product: product} do
      {:ok, asset} =
        ProductAssets.create_asset(%{
          product_id: product.id,
          storage_key: "products/#{product.id}/assets/bundle-shot",
          media_type: "image",
          filename: "bundle-shot.jpg",
          mime_type: "image/jpeg",
          byte_size: 2048,
          uploaded_at: DateTime.utc_now()
        })

      body = %{
        "channel" => "cli",
        "sender_identity" => "cli:writer",
        "params" => %{
          "product" => product.id,
          "asset_id" => asset.id,
          "tag" => "Autumn"
        }
      }

      conn =
        conn
        |> put_req_header("x-openclaw-tool-secret", @secret)
        |> post(~p"/api/v1/openclaw/tools/add_tag_to_asset", body)

      assert %{
               "status" => "ok",
               "result" => %{"asset_id" => id, "tags" => ["autumn"]}
             } = json_response(conn, 200)

      assert id == asset.id
    end

    test "add_tag_to_asset 422 not_found when the asset belongs to another product",
         %{conn: conn, product: product} do
      {:ok, other} =
        Products.create_product(%{name: "Otherland", voice_profile: "warm"})

      {:ok, other_asset} =
        ProductAssets.create_asset(%{
          product_id: other.id,
          storage_key: "products/#{other.id}/assets/foreign",
          media_type: "image",
          filename: "foreign.jpg",
          mime_type: "image/jpeg",
          byte_size: 1024,
          uploaded_at: DateTime.utc_now()
        })

      body = %{
        "channel" => "cli",
        "sender_identity" => "cli:writer",
        "params" => %{
          "product" => product.id,
          "asset_id" => other_asset.id,
          "tag" => "summer"
        }
      }

      conn =
        conn
        |> put_req_header("x-openclaw-tool-secret", @secret)
        |> post(~p"/api/v1/openclaw/tools/add_tag_to_asset", body)

      assert %{"status" => "error", "error" => "not_found"} =
               json_response(conn, 422)
    end
  end

  describe "16.3d record_memory" do
    setup do
      {:ok, product} =
        Products.create_product(%{name: "Memory Co", voice_profile: "warm"})

      {:ok, _} =
        Operators.create_identity(%{
          product_id: product.id,
          identity: "cli:recorder",
          role: "submitter"
        })

      %{product: product}
    end

    test "dispatches record_memory through the full HTTP pipeline",
         %{conn: conn, product: product} do
      body = %{
        "session_id" => "sess-42",
        "channel" => "cli",
        "sender_identity" => "cli:recorder",
        "params" => %{
          "product" => product.id,
          "content" => "Client prefers matte finishes.",
          "tags" => ["preference"]
        }
      }

      conn =
        conn
        |> put_req_header("x-openclaw-tool-secret", @secret)
        |> post(~p"/api/v1/openclaw/tools/record_memory", body)

      assert %{
               "status" => "ok",
               "result" => %{
                 "memory_id" => memory_id,
                 "product_id" => pid,
                 "session_id" => "sess-42",
                 "recorded_at" => recorded_at
               }
             } = json_response(conn, 200)

      assert pid == product.id
      assert is_binary(memory_id)
      assert is_binary(recorded_at)

      [row] = Products.list_recent_memories(product.id)
      assert row.id == memory_id
      assert row.tags == ["preference"]
    end

    test "record_memory 422 empty_content when content is whitespace",
         %{conn: conn, product: product} do
      body = %{
        "session_id" => "sess-42",
        "channel" => "cli",
        "sender_identity" => "cli:recorder",
        "params" => %{"product" => product.id, "content" => "   "}
      }

      conn =
        conn
        |> put_req_header("x-openclaw-tool-secret", @secret)
        |> post(~p"/api/v1/openclaw/tools/record_memory", body)

      assert %{"status" => "error", "error" => "empty_content"} =
               json_response(conn, 422)
    end
  end

  describe "16.4a confirmation_required response" do
    defmodule ConfirmationRequiredStub do
      @moduledoc false
      def call(_ctx, _params) do
        {:ok, :confirmation_required,
         %{
           echo_phrase: "crimson-otter-harbor",
           expires_at: ~U[2030-01-01 00:05:00.000000Z],
           preview: %{
             summary: "preview summary the agent will read",
             draft_id: "d-1",
             publish_gate: :passes
           }
         }}
      end
    end

    setup do
      original = Application.get_env(:content_forge, :extra_open_claw_tools, %{})

      Application.put_env(
        :content_forge,
        :extra_open_claw_tools,
        Map.put(original, "__test_confirmation_required__", ConfirmationRequiredStub)
      )

      on_exit(fn ->
        Application.put_env(:content_forge, :extra_open_claw_tools, original)
      end)

      :ok
    end

    test "200 with status=confirmation_required and a serialized envelope",
         %{conn: conn} do
      body = %{
        "session_id" => "sess-42",
        "channel" => "cli",
        "sender_identity" => "cli:ops",
        "params" => %{"foo" => "bar"}
      }

      conn =
        conn
        |> put_req_header("x-openclaw-tool-secret", @secret)
        |> post(~p"/api/v1/openclaw/tools/__test_confirmation_required__", body)

      assert %{
               "status" => "confirmation_required",
               "echo_phrase" => "crimson-otter-harbor",
               "expires_at" => "2030-01-01T00:05:00.000000Z",
               "preview" => %{
                 "summary" => "preview summary the agent will read",
                 "draft_id" => "d-1",
                 "publish_gate" => "passes"
               }
             } = json_response(conn, 200)
    end
  end
end
