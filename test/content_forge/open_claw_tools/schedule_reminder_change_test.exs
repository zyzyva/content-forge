defmodule ContentForge.OpenClawTools.ScheduleReminderChangeTest do
  @moduledoc """
  Phase 16.4c: heavy-write tool that flips `ReminderConfig`
  cadence / enabled behind the two-turn confirmation envelope.
  No-op requests (same cadence + same enabled) short-circuit
  without asking for confirmation; actual changes run through
  `Confirmation.request/4` + `Confirmation.confirm/4`.
  """
  use ContentForge.DataCase, async: false

  alias ContentForge.OpenClawTools.PendingConfirmation
  alias ContentForge.OpenClawTools.ScheduleReminderChange
  alias ContentForge.Operators
  alias ContentForge.Products
  alias ContentForge.Repo
  alias ContentForge.Sms
  alias ContentForge.Sms.ReminderConfig

  setup do
    {:ok, product} =
      Products.create_product(%{name: "Nudgeland", voice_profile: "warm"})

    %{product: product}
  end

  defp cli_ctx(identity, role, product, session_id \\ "sess-remind") do
    {:ok, _} =
      Operators.create_identity(%{
        product_id: product.id,
        identity: identity,
        role: role
      })

    %{channel: "cli", sender_identity: identity, session_id: session_id}
  end

  describe "authorization" do
    test "submitter role returns :forbidden without inserting a pending row",
         %{product: product} do
      ctx = cli_ctx("cli:submitter", "submitter", product)

      assert {:error, :forbidden} =
               ScheduleReminderChange.call(ctx, %{
                 "product" => product.id,
                 "cadence_days" => 10
               })

      assert Repo.aggregate(PendingConfirmation, :count, :id) == 0
    end
  end

  describe "validation" do
    test "cadence_days outside 1..30 returns :invalid_cadence",
         %{product: product} do
      ctx = cli_ctx("cli:bad-cad", "owner", product)

      assert {:error, :invalid_cadence} =
               ScheduleReminderChange.call(ctx, %{
                 "product" => product.id,
                 "cadence_days" => 0
               })

      assert {:error, :invalid_cadence} =
               ScheduleReminderChange.call(ctx, %{
                 "product" => product.id,
                 "cadence_days" => 31
               })

      assert {:error, :invalid_cadence} =
               ScheduleReminderChange.call(ctx, %{
                 "product" => product.id,
                 "cadence_days" => "ten"
               })

      assert {:error, :invalid_cadence} =
               ScheduleReminderChange.call(ctx, %{"product" => product.id})
    end

    test "non-boolean enabled returns :invalid_enabled", %{product: product} do
      ctx = cli_ctx("cli:bad-en", "owner", product)

      assert {:error, :invalid_enabled} =
               ScheduleReminderChange.call(ctx, %{
                 "product" => product.id,
                 "cadence_days" => 7,
                 "enabled" => "yes"
               })
    end
  end

  describe "first turn" do
    test "changed request returns confirmation envelope with before/after diff",
         %{product: product} do
      # Seed the baseline so the tool has concrete before-values to echo.
      {:ok, _} =
        Sms.upsert_reminder_config(product.id, %{enabled: true, cadence_days: 7})

      ctx = cli_ctx("cli:change", "owner", product, "sess-change")

      assert {:ok, :confirmation_required, envelope} =
               ScheduleReminderChange.call(ctx, %{
                 "product" => product.id,
                 "cadence_days" => 3
               })

      assert is_binary(envelope.echo_phrase)

      preview = envelope.preview
      assert preview.product_id == product.id
      assert %{cadence_days: 7, enabled: true} = preview.before
      assert %{cadence_days: 3, enabled: true} = preview.after
      assert is_binary(preview.summary)
    end

    test "no-op request (same cadence + same enabled) short-circuits without a pending row",
         %{product: product} do
      {:ok, _} =
        Sms.upsert_reminder_config(product.id, %{enabled: true, cadence_days: 7})

      ctx = cli_ctx("cli:noop", "owner", product, "sess-noop")

      assert {:ok, %{changed: false, cadence_days: 7, enabled: true, product_id: pid}} =
               ScheduleReminderChange.call(ctx, %{
                 "product" => product.id,
                 "cadence_days" => 7,
                 "enabled" => true
               })

      assert pid == product.id
      assert Repo.aggregate(PendingConfirmation, :count, :id) == 0
    end

    test "default enabled treats a missing key as true", %{product: product} do
      {:ok, _} =
        Sms.upsert_reminder_config(product.id, %{enabled: true, cadence_days: 5})

      ctx = cli_ctx("cli:default-en", "owner", product, "sess-def")

      assert {:ok, %{changed: false}} =
               ScheduleReminderChange.call(ctx, %{
                 "product" => product.id,
                 "cadence_days" => 5
               })
    end

    test "uses schema defaults when no row exists yet", %{product: product} do
      # No upsert; the tool should read defaults through
      # Sms.get_reminder_config/1 (enabled: true, cadence_days: 7).
      ctx = cli_ctx("cli:no-row", "owner", product, "sess-nr")

      assert {:ok, :confirmation_required, envelope} =
               ScheduleReminderChange.call(ctx, %{
                 "product" => product.id,
                 "cadence_days" => 3
               })

      assert %{cadence_days: 7, enabled: true} = envelope.preview.before
    end
  end

  describe "second turn" do
    test "correct confirm persists the change and returns updated_at",
         %{product: product} do
      {:ok, _} =
        Sms.upsert_reminder_config(product.id, %{enabled: true, cadence_days: 7})

      ctx = cli_ctx("cli:persist", "owner", product, "sess-persist")
      params = %{"product" => product.id, "cadence_days" => 3, "enabled" => false}

      {:ok, :confirmation_required, envelope} = ScheduleReminderChange.call(ctx, params)
      confirm_params = Map.put(params, "confirm", envelope.echo_phrase)

      assert {:ok, result} = ScheduleReminderChange.call(ctx, confirm_params)

      assert result.changed == true
      assert result.cadence_days == 3
      assert result.enabled == false
      assert is_binary(result.updated_at)

      assert %ReminderConfig{cadence_days: 3, enabled: false} =
               Repo.get_by(ReminderConfig, product_id: product.id)
    end

    test "wrong echo phrase returns :confirmation_not_found and makes no change",
         %{product: product} do
      {:ok, _} =
        Sms.upsert_reminder_config(product.id, %{enabled: true, cadence_days: 7})

      ctx = cli_ctx("cli:wrong-conf", "owner", product, "sess-wrong-conf")

      assert {:error, :confirmation_not_found} =
               ScheduleReminderChange.call(ctx, %{
                 "product" => product.id,
                 "cadence_days" => 3,
                 "confirm" => "nope-never-anywhere"
               })

      assert %ReminderConfig{cadence_days: 7} =
               Repo.get_by(ReminderConfig, product_id: product.id)
    end
  end

  describe "product resolution" do
    test "ambiguous product = :ambiguous_product without inserting a row",
         %{product: _product} do
      {:ok, _} = Products.create_product(%{name: "Shared Remind Alpha", voice_profile: "warm"})
      {:ok, _} = Products.create_product(%{name: "Shared Remind Beta", voice_profile: "warm"})

      ctx = %{channel: "cli", sender_identity: "cli:unused", session_id: "sess-amb"}

      assert {:error, :ambiguous_product} =
               ScheduleReminderChange.call(ctx, %{
                 "product" => "shared remind",
                 "cadence_days" => 7
               })
    end
  end
end
