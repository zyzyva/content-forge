defmodule ContentForge.OpenClawTools.ConfirmationTest do
  @moduledoc """
  Phase 16.4a: `Confirmation` is the shared infra every
  heavy-write tool pipes through. These tests lock in the
  request / confirm contract: idempotent ask, single-use
  consume, atomic update on race, classified failures the
  controller can serialize.
  """
  use ContentForge.DataCase, async: false

  alias ContentForge.OpenClawTools.Confirmation
  alias ContentForge.OpenClawTools.PendingConfirmation
  alias ContentForge.Repo
  alias Ecto.Adapters.SQL.Sandbox

  defp ctx(session_id \\ "sess-42") do
    %{channel: "cli", sender_identity: "cli:ops", session_id: session_id}
  end

  defp params(overrides \\ %{}) do
    Map.merge(%{"draft_id" => "d-1", "override_reason" => nil}, overrides)
  end

  defp preview, do: %{summary: "approve the winter promo blog post"}

  describe "request/4" do
    test "inserts a fresh pending row and returns echo phrase + expiry + preview" do
      assert {:ok, envelope} =
               Confirmation.request("approve_draft", ctx(), params(), preview())

      assert is_binary(envelope.echo_phrase)
      assert envelope.echo_phrase =~ ~r/^[a-z]+-[a-z]+-[a-z]+$/
      assert %DateTime{} = envelope.expires_at

      now = DateTime.utc_now()
      assert DateTime.compare(envelope.expires_at, now) == :gt
      assert envelope.preview == preview()

      [row] = Repo.all(PendingConfirmation)
      assert row.tool_name == "approve_draft"
      assert row.echo_phrase == envelope.echo_phrase
      assert row.consumed_at == nil
    end

    test "is idempotent: same (session, tool, params_hash) returns the same phrase" do
      {:ok, first} = Confirmation.request("approve_draft", ctx(), params(), preview())

      {:ok, second} =
        Confirmation.request("approve_draft", ctx(), params(), preview())

      assert first.echo_phrase == second.echo_phrase
      assert DateTime.compare(first.expires_at, second.expires_at) == :eq
      assert Repo.aggregate(PendingConfirmation, :count, :id) == 1
    end

    test "different params mint a fresh phrase (not a collision)" do
      {:ok, first} = Confirmation.request("approve_draft", ctx(), params(), preview())

      {:ok, second} =
        Confirmation.request(
          "approve_draft",
          ctx(),
          params(%{"draft_id" => "d-2"}),
          preview()
        )

      assert first.echo_phrase != second.echo_phrase
      assert Repo.aggregate(PendingConfirmation, :count, :id) == 2
    end

    test "a `confirm` key in params is excluded from the hash so a repeat ask stays idempotent" do
      {:ok, first} =
        Confirmation.request("approve_draft", ctx(), params(), preview())

      {:ok, second} =
        Confirmation.request(
          "approve_draft",
          ctx(),
          params(%{"confirm" => first.echo_phrase}),
          preview()
        )

      assert first.echo_phrase == second.echo_phrase
      assert Repo.aggregate(PendingConfirmation, :count, :id) == 1
    end

    test "missing session_id returns :missing_session without inserting" do
      ctx_without_session = %{channel: "cli", sender_identity: "cli:ops"}

      assert {:error, :missing_session} =
               Confirmation.request(
                 "approve_draft",
                 ctx_without_session,
                 params(),
                 preview()
               )

      assert Repo.aggregate(PendingConfirmation, :count, :id) == 0
    end

    test "expired existing rows do not block a fresh request" do
      # Insert a row that looks expired: past expires_at and unconsumed.
      past = DateTime.add(DateTime.utc_now(), -600, :second)
      {:ok, _} = Confirmation.request("approve_draft", ctx(), params(), preview())

      from(p in PendingConfirmation)
      |> Repo.update_all(set: [expires_at: past])

      assert {:ok, fresh} =
               Confirmation.request("approve_draft", ctx(), params(), preview())

      assert DateTime.compare(fresh.expires_at, DateTime.utc_now()) == :gt
      assert Repo.aggregate(PendingConfirmation, :count, :id) == 2
    end
  end

  describe "confirm/4" do
    test "happy path: matching phrase consumes the row and returns :ok" do
      {:ok, envelope} =
        Confirmation.request("approve_draft", ctx(), params(), preview())

      assert :ok =
               Confirmation.confirm("approve_draft", ctx(), params(), envelope.echo_phrase)

      [row] = Repo.all(PendingConfirmation)
      assert %DateTime{} = row.consumed_at
    end

    test "wrong tool_name returns :confirmation_mismatch without consuming" do
      {:ok, envelope} =
        Confirmation.request("approve_draft", ctx(), params(), preview())

      assert {:error, :confirmation_mismatch} =
               Confirmation.confirm(
                 "schedule_reminder_change",
                 ctx(),
                 params(),
                 envelope.echo_phrase
               )

      [row] = Repo.all(PendingConfirmation)
      assert row.consumed_at == nil
    end

    test "mismatched params hash returns :confirmation_mismatch without consuming" do
      {:ok, envelope} =
        Confirmation.request("approve_draft", ctx(), params(), preview())

      assert {:error, :confirmation_mismatch} =
               Confirmation.confirm(
                 "approve_draft",
                 ctx(),
                 params(%{"draft_id" => "different"}),
                 envelope.echo_phrase
               )

      [row] = Repo.all(PendingConfirmation)
      assert row.consumed_at == nil
    end

    test "unknown phrase returns :confirmation_not_found" do
      assert {:error, :confirmation_not_found} =
               Confirmation.confirm(
                 "approve_draft",
                 ctx(),
                 params(),
                 "amber-fox-meadow"
               )
    end

    test "already-consumed phrase returns :confirmation_not_found" do
      {:ok, envelope} =
        Confirmation.request("approve_draft", ctx(), params(), preview())

      :ok = Confirmation.confirm("approve_draft", ctx(), params(), envelope.echo_phrase)

      assert {:error, :confirmation_not_found} =
               Confirmation.confirm(
                 "approve_draft",
                 ctx(),
                 params(),
                 envelope.echo_phrase
               )
    end

    test "expired phrase returns :confirmation_expired" do
      {:ok, envelope} =
        Confirmation.request("approve_draft", ctx(), params(), preview())

      past = DateTime.add(DateTime.utc_now(), -60, :second)

      from(p in PendingConfirmation)
      |> Repo.update_all(set: [expires_at: past])

      assert {:error, :confirmation_expired} =
               Confirmation.confirm(
                 "approve_draft",
                 ctx(),
                 params(),
                 envelope.echo_phrase
               )
    end

    test "confirm with a `confirm` key in params still hashes by the stable canonical form" do
      {:ok, envelope} =
        Confirmation.request("approve_draft", ctx(), params(), preview())

      # Simulating the real flow: the second-turn params may carry the
      # echo phrase under the `confirm` key. The hash strips that so
      # the match against the first-turn row still works.
      assert :ok =
               Confirmation.confirm(
                 "approve_draft",
                 ctx(),
                 params(%{"confirm" => envelope.echo_phrase}),
                 envelope.echo_phrase
               )
    end

    test "concurrent confirms land exactly one :ok and one :confirmation_not_found" do
      {:ok, envelope} =
        Confirmation.request("approve_draft", ctx(), params(), preview())

      # Each parent checkout is shared to children via the shared
      # sandbox; DataCase.setup_sandbox with `shared: true` is
      # already applied for non-async tests.
      parent = self()

      [task_a, task_b] =
        for _ <- 1..2 do
          Task.async(fn ->
            Sandbox.allow(Repo, parent, self())

            Confirmation.confirm(
              "approve_draft",
              ctx(),
              params(),
              envelope.echo_phrase
            )
          end)
        end

      results = [Task.await(task_a), Task.await(task_b)] |> Enum.sort()
      assert results == [:ok, {:error, :confirmation_not_found}]
    end

    test "missing session_id returns :missing_session" do
      ctx_without_session = %{channel: "cli", sender_identity: "cli:ops"}

      assert {:error, :missing_session} =
               Confirmation.confirm(
                 "approve_draft",
                 ctx_without_session,
                 params(),
                 "amber-fox-meadow"
               )
    end
  end
end
