defmodule ContentForge.OpenClawTools.ApproveDraftTest do
  @moduledoc """
  Phase 16.4b: first consumer of the two-turn confirmation
  envelope. Gates through :owner, routes to the 12.4 publish
  gate (or the override path when the gate would block and the
  caller supplies a reason), and returns a preview the agent
  reads back verbatim before asking for the echo phrase.
  """
  use ContentForge.DataCase, async: false

  alias ContentForge.ContentGeneration
  alias ContentForge.ContentGeneration.Draft
  alias ContentForge.OpenClawTools.ApproveDraft
  alias ContentForge.OpenClawTools.PendingConfirmation
  alias ContentForge.Operators
  alias ContentForge.Products
  alias ContentForge.Repo
  alias ContentForge.Sms

  setup do
    {:ok, product} =
      Products.create_product(%{name: "Approveland", voice_profile: "warm"})

    %{product: product}
  end

  defp sms_ctx(phone, role, product, session_id \\ "sess-approve") do
    {:ok, _} =
      Sms.create_phone(%{
        product_id: product.id,
        phone_number: phone,
        role: role,
        active: true
      })

    %{channel: "sms", sender_identity: phone, session_id: session_id, product: product}
  end

  defp cli_owner_ctx(identity, product, session_id \\ "sess-cli") do
    {:ok, _} =
      Operators.create_identity(%{
        product_id: product.id,
        identity: identity,
        role: "owner"
      })

    %{channel: "cli", sender_identity: identity, session_id: session_id}
  end

  defp insert_draft(product, attrs) do
    base = %{
      product_id: product.id,
      content: "Body of the draft.",
      platform: "blog",
      content_type: "blog",
      generating_model: "stub-model",
      status: "ranked",
      angle: "case_study",
      seo_score: 25,
      research_status: "enriched"
    }

    {:ok, draft} =
      %Draft{}
      |> Draft.changeset(Map.merge(base, attrs))
      |> Repo.insert()

    draft
  end

  describe "call/2 authorization" do
    test "submitter role returns :forbidden", %{product: product} do
      draft = insert_draft(product, %{})
      ctx = sms_ctx("+15550000001", "submitter", product)

      assert {:error, :forbidden} =
               ApproveDraft.call(ctx, %{"product" => product.id, "draft_id" => draft.id})

      assert Repo.aggregate(PendingConfirmation, :count, :id) == 0
    end

    test "unknown sender returns :forbidden even when the draft exists",
         %{product: product} do
      draft = insert_draft(product, %{})
      ctx = %{channel: "cli", sender_identity: "cli:stranger", session_id: "s1"}

      assert {:error, :forbidden} =
               ApproveDraft.call(ctx, %{"product" => product.id, "draft_id" => draft.id})
    end
  end

  describe "call/2 draft scoping" do
    test "cross-product draft_id returns :not_found",
         %{product: product} do
      {:ok, other} =
        Products.create_product(%{name: "Outland", voice_profile: "warm"})

      other_draft = insert_draft(other, %{})
      ctx = cli_owner_ctx("cli:cross", product)

      assert {:error, :not_found} =
               ApproveDraft.call(ctx, %{
                 "product" => product.id,
                 "draft_id" => other_draft.id
               })
    end

    test "unknown draft_id returns :not_found", %{product: product} do
      ctx = cli_owner_ctx("cli:nodraft", product)

      assert {:error, :not_found} =
               ApproveDraft.call(ctx, %{
                 "product" => product.id,
                 "draft_id" => Ecto.UUID.generate()
               })
    end

    test "malformed draft_id returns :not_found", %{product: product} do
      ctx = cli_owner_ctx("cli:bad", product)

      assert {:error, :not_found} =
               ApproveDraft.call(ctx, %{
                 "product" => product.id,
                 "draft_id" => "not-a-uuid"
               })
    end
  end

  describe "first-turn confirmation request" do
    test "gate-pass draft yields preview with publish_gate: :passes",
         %{product: product} do
      draft = insert_draft(product, %{seo_score: 30, research_status: "enriched"})
      ctx = cli_owner_ctx("cli:gate-pass", product, "sess-pass")

      assert {:ok, :confirmation_required, envelope} =
               ApproveDraft.call(ctx, %{"product" => product.id, "draft_id" => draft.id})

      assert is_binary(envelope.echo_phrase)
      assert %DateTime{} = envelope.expires_at

      preview = envelope.preview
      assert preview.draft_id == draft.id
      assert preview.platform == "blog"
      assert preview.content_type == "blog"
      assert preview.angle == "case_study"
      assert preview.publish_gate == :passes
      assert preview.required_override == false
      assert preview.override_reason_present == false
      assert is_binary(preview.snippet)
      assert is_binary(preview.summary)
    end

    test "gate-block draft (no reason) yields preview with publish_gate: :blocks and required_override: true",
         %{product: product} do
      draft =
        insert_draft(product, %{seo_score: 5, research_status: "enriched"})

      ctx = cli_owner_ctx("cli:gate-block", product, "sess-block")

      assert {:ok, :confirmation_required, envelope} =
               ApproveDraft.call(ctx, %{"product" => product.id, "draft_id" => draft.id})

      preview = envelope.preview
      assert preview.publish_gate == :blocks
      assert preview.required_override == true
      assert preview.override_reason_present == false
    end

    test "gate-block draft with override_reason yields override_reason_present: true",
         %{product: product} do
      draft = insert_draft(product, %{seo_score: 5})
      ctx = cli_owner_ctx("cli:override", product, "sess-override")

      assert {:ok, :confirmation_required, envelope} =
               ApproveDraft.call(ctx, %{
                 "product" => product.id,
                 "draft_id" => draft.id,
                 "override_reason" => "SEO audit flagged but copy is final"
               })

      preview = envelope.preview
      assert preview.publish_gate == :blocks
      assert preview.required_override == true
      assert preview.override_reason_present == true
    end

    test "idempotent: same (session, draft_id, override_reason) returns the same phrase",
         %{product: product} do
      draft = insert_draft(product, %{seo_score: 30})
      ctx = cli_owner_ctx("cli:idemp", product, "sess-idemp")
      params = %{"product" => product.id, "draft_id" => draft.id}

      assert {:ok, :confirmation_required, first} = ApproveDraft.call(ctx, params)
      assert {:ok, :confirmation_required, second} = ApproveDraft.call(ctx, params)

      assert first.echo_phrase == second.echo_phrase
      assert Repo.aggregate(PendingConfirmation, :count, :id) == 1
    end

    test "non-blog drafts report publish_gate: :passes regardless of seo_score",
         %{product: product} do
      draft =
        insert_draft(product, %{
          content_type: "post",
          platform: "twitter",
          seo_score: 0
        })

      ctx = cli_owner_ctx("cli:non-blog", product, "sess-nb")

      assert {:ok, :confirmation_required, envelope} =
               ApproveDraft.call(ctx, %{"product" => product.id, "draft_id" => draft.id})

      assert envelope.preview.publish_gate == :passes
      assert envelope.preview.required_override == false
    end
  end

  describe "second-turn confirmation execute" do
    test "correct confirm on gate-pass flips the draft to approved",
         %{product: product} do
      draft = insert_draft(product, %{seo_score: 30})
      ctx = cli_owner_ctx("cli:approve", product, "sess-approve-ok")

      params = %{"product" => product.id, "draft_id" => draft.id}
      {:ok, :confirmation_required, envelope} = ApproveDraft.call(ctx, params)

      confirm_params = Map.put(params, "confirm", envelope.echo_phrase)

      assert {:ok, result} = ApproveDraft.call(ctx, confirm_params)

      assert result.draft_id == draft.id
      assert result.status == "approved"
      assert result.approved_via_override == false
      assert is_binary(result.approved_at)
      assert result.override_reason == nil

      updated = ContentGeneration.get_draft(draft.id)
      assert updated.status == "approved"
      assert updated.approved_via_override == false
    end

    test "correct confirm on gate-block + override_reason takes the override path",
         %{product: product} do
      draft = insert_draft(product, %{seo_score: 5})
      ctx = cli_owner_ctx("cli:override-execute", product, "sess-override-ex")

      params = %{
        "product" => product.id,
        "draft_id" => draft.id,
        "override_reason" => "SEO audit flagged but the copy is final and on-brand"
      }

      {:ok, :confirmation_required, envelope} = ApproveDraft.call(ctx, params)
      confirm_params = Map.put(params, "confirm", envelope.echo_phrase)

      assert {:ok, result} = ApproveDraft.call(ctx, confirm_params)

      assert result.status == "approved"
      assert result.approved_via_override == true
      assert result.override_reason =~ "SEO audit"

      updated = ContentGeneration.get_draft(draft.id)
      assert updated.approved_via_override == true
      assert updated.override_reason =~ "SEO audit"
    end

    test "gate-block without override_reason returns :publish_gate_blocks on confirm",
         %{product: product} do
      draft = insert_draft(product, %{seo_score: 5})
      ctx = cli_owner_ctx("cli:block", product, "sess-block-execute")

      params = %{"product" => product.id, "draft_id" => draft.id}
      {:ok, :confirmation_required, envelope} = ApproveDraft.call(ctx, params)
      confirm_params = Map.put(params, "confirm", envelope.echo_phrase)

      assert {:error, :publish_gate_blocks} = ApproveDraft.call(ctx, confirm_params)

      # Draft is unchanged.
      unchanged = ContentGeneration.get_draft(draft.id)
      assert unchanged.status == "ranked"
    end

    test "mismatched override_reason between request and confirm = :confirmation_mismatch",
         %{product: product} do
      draft = insert_draft(product, %{seo_score: 5})
      ctx = cli_owner_ctx("cli:mismatch", product, "sess-mismatch")

      request_params = %{
        "product" => product.id,
        "draft_id" => draft.id,
        "override_reason" => "first reason"
      }

      {:ok, :confirmation_required, envelope} = ApproveDraft.call(ctx, request_params)

      confirm_params =
        request_params
        |> Map.put("override_reason", "a completely different reason")
        |> Map.put("confirm", envelope.echo_phrase)

      assert {:error, :confirmation_mismatch} = ApproveDraft.call(ctx, confirm_params)

      unchanged = ContentGeneration.get_draft(draft.id)
      assert unchanged.status == "ranked"
    end

    test "wrong echo phrase returns :confirmation_not_found", %{product: product} do
      draft = insert_draft(product, %{seo_score: 30})
      ctx = cli_owner_ctx("cli:wrong-echo", product, "sess-wrong")

      assert {:error, :confirmation_not_found} =
               ApproveDraft.call(ctx, %{
                 "product" => product.id,
                 "draft_id" => draft.id,
                 "confirm" => "nope-never-anywhere"
               })
    end
  end
end
