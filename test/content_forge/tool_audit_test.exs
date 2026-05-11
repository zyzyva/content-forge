defmodule ContentForge.ToolAuditTest do
  use ContentForge.DataCase, async: true

  alias ContentForge.Products
  alias ContentForge.ToolAudit
  alias ContentForge.ToolAudit.ToolInvocationEvent

  describe "hash_pii/1" do
    test "returns a deterministic short SHA-256 base64 string for a phone number" do
      h1 = ToolAudit.hash_pii("+15551234567")
      h2 = ToolAudit.hash_pii("+15551234567")
      assert h1 == h2
      assert String.starts_with?(h1, "sha256:")
      # Hash output should not echo the plaintext.
      refute h1 =~ "5551234567"
    end

    test "returns nil for nil and empty" do
      assert ToolAudit.hash_pii(nil) == nil
      assert ToolAudit.hash_pii("") == nil
    end

    test "different inputs produce different hashes" do
      a = ToolAudit.hash_pii("+15551234567")
      b = ToolAudit.hash_pii("+15559999999")
      assert a != b
    end
  end

  describe "redact/2" do
    test "hashes values for keys in the redact list" do
      params = %{"phone_number" => "+15551234567", "product" => "Acme"}
      out = ToolAudit.redact(params, ["phone_number"])
      assert String.starts_with?(out["phone_number"], "sha256:")
      assert out["product"] == "Acme"
    end

    test "leaves the map unchanged when no keys match" do
      params = %{"product" => "Acme", "filename" => "x.txt"}
      assert ToolAudit.redact(params, ["phone_number", "email"]) == params
    end

    test "redacts atom-keyed maps consistently" do
      params = %{phone_number: "+15551234567"}
      out = ToolAudit.redact(params, ["phone_number"])
      assert String.starts_with?(out[:phone_number] || out["phone_number"], "sha256:")
    end

    test "no-ops on non-binary values for redacted keys (does not crash)" do
      params = %{"phone_number" => nil, "email" => 42}
      out = ToolAudit.redact(params, ["phone_number", "email"])
      assert out["phone_number"] == nil
      assert out["email"] == 42
    end
  end

  describe "normalize_result/1" do
    test "{:ok, map} -> ok status with no summary" do
      assert {"ok", nil} = ToolAudit.normalize_result({:ok, %{result: 1}})
    end

    test "{:ok, :confirmation_required, envelope} -> confirmation_required status" do
      assert {"confirmation_required", nil} =
               ToolAudit.normalize_result({:ok, :confirmation_required, %{echo_phrase: "x"}})
    end

    test "{:error, atom} -> error status with atom name as summary" do
      assert {"error", "forbidden"} = ToolAudit.normalize_result({:error, :forbidden})
    end

    test "{:error, :unknown_tool} -> unknown_tool status" do
      assert {"unknown_tool", "unknown_tool"} =
               ToolAudit.normalize_result({:error, :unknown_tool})
    end

    test "{:error, {:tag, details}} -> error status, tag as summary" do
      assert {"error", "presign_failed"} =
               ToolAudit.normalize_result({:error, {:presign_failed, "boom"}})
    end

    test "{:error, %{code: code}} (mcp envelope) -> error status, code as summary" do
      result = {:error, %{code: "validation_failed", message: "bad"}}
      assert {"error", "validation_failed"} = ToolAudit.normalize_result(result)
    end
  end

  describe "log_invocation/4 (insert-only audit row)" do
    test "persists a row with hashed sender_identity, redacted PII params, and ok status" do
      ctx = %{channel: "openclaw_cli", sender_identity: "+15551234567"}
      params = %{"product" => "Acme", "filename" => "x.txt"}
      result = {:ok, %{url: "https://example/upload", product_id: nil}}

      assert {:ok, %ToolInvocationEvent{} = event} =
               ToolAudit.log_invocation("create_upload_link", ctx, params, result, %{
                 duration_ms: 12
               })

      assert event.tool_name == "create_upload_link"
      assert event.channel == "openclaw_cli"
      assert String.starts_with?(event.sender_identity, "sha256:")
      assert event.result_status == "ok"
      assert event.result_summary == nil
      assert event.duration_ms == 12
      assert %DateTime{} = event.invoked_at
    end

    test "extracts product_id from the result envelope when present" do
      {:ok, product} =
        Products.create_product(%{
          name: "Audit Product #{System.unique_integer()}",
          voice_profile: "professional"
        })

      ctx = %{channel: "openclaw_sms", sender_identity: "+15551112222"}
      result = {:ok, %{product_id: product.id, product_name: product.name}}

      assert {:ok, event} =
               ToolAudit.log_invocation("draft_status", ctx, %{}, result)

      assert event.product_id == product.id
    end

    test "stores nil product_id when neither ctx, params, nor result carry one" do
      assert {:ok, event} =
               ToolAudit.log_invocation(
                 "list_recent_assets",
                 %{channel: "mcp"},
                 %{},
                 {:error, :missing_product_context}
               )

      assert event.product_id == nil
      assert event.result_status == "error"
      assert event.result_summary == "missing_product_context"
    end

    test "passes non-phone sender_identity (cli:ops, mcp) through unchanged" do
      ctx = %{channel: "openclaw_cli", sender_identity: "cli:ops"}

      assert {:ok, event} =
               ToolAudit.log_invocation(
                 "create_upload_link",
                 ctx,
                 %{},
                 {:ok, %{url: "u"}}
               )

      assert event.sender_identity == "cli:ops"
    end

    test "redacts pii_keys configured per tool name" do
      Application.put_env(:content_forge, :tool_audit,
        pii_keys_per_tool: %{"my_pii_tool" => ["secret_field"]}
      )

      on_exit(fn -> Application.delete_env(:content_forge, :tool_audit) end)

      ctx = %{channel: "mcp"}
      params = %{"secret_field" => "shh-this-is-private", "ok_field" => "Acme"}

      assert {:ok, event} =
               ToolAudit.log_invocation("my_pii_tool", ctx, params, {:ok, %{}})

      assert String.starts_with?(event.params["secret_field"], "sha256:")
      assert event.params["ok_field"] == "Acme"
    end
  end

  describe "list_for_product/2 + list_recent/1 (read API for dashboard + REST)" do
    setup do
      {:ok, product} =
        Products.create_product(%{
          name: "Audit Read #{System.unique_integer()}",
          voice_profile: "professional"
        })

      {:ok, e1} =
        ToolAudit.log_invocation(
          "create_upload_link",
          %{channel: "openclaw_cli"},
          %{},
          {:ok, %{product_id: product.id}}
        )

      {:ok, e2} =
        ToolAudit.log_invocation(
          "draft_status",
          %{channel: "mcp"},
          %{},
          {:error, :forbidden},
          %{product_id: product.id}
        )

      {:ok, _other} =
        ToolAudit.log_invocation(
          "create_upload_link",
          %{channel: "openclaw_sms"},
          %{},
          {:ok, %{}}
        )

      %{product: product, e1: e1, e2: e2}
    end

    test "list_for_product/2 returns events for that product, newest first", %{
      product: product
    } do
      events = ToolAudit.list_for_product(product.id, [])
      assert length(events) == 2
      assert Enum.all?(events, &(&1.product_id == product.id))
    end

    test "filter by tool", %{product: product} do
      assert [%{tool_name: "draft_status"}] =
               ToolAudit.list_for_product(product.id, tool: "draft_status")
    end

    test "filter by channel", %{product: product} do
      assert [%{channel: "mcp"}] =
               ToolAudit.list_for_product(product.id, channel: "mcp")
    end

    test "filter by status", %{product: product} do
      assert [%{result_status: "error"}] =
               ToolAudit.list_for_product(product.id, status: "error")
    end

    test "list_recent/1 returns all events newest first across products" do
      events = ToolAudit.list_recent([])
      # 3 inserted in setup; could include rows from other tests if not async
      assert length(events) >= 3
    end

    test "limit caps result count" do
      assert events = ToolAudit.list_recent(limit: 2)
      assert length(events) == 2
    end
  end
end
