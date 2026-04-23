defmodule ContentForge.OpenClawTools.PendingConfirmationTest do
  @moduledoc """
  Phase 16.4a: schema-level invariants for the two-turn
  confirmation persistence. Drives the shape the `Confirmation`
  context relies on: required fields, the partial unique index
  on `(session_id, echo_phrase) WHERE consumed_at IS NULL`, and
  the append-only semantics (consume via update, never delete).
  """
  use ContentForge.DataCase, async: false

  alias ContentForge.OpenClawTools.PendingConfirmation
  alias ContentForge.Repo

  defp valid_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        session_id: "session-abc",
        tool_name: "approve_draft",
        params_hash: String.duplicate("a", 64),
        echo_phrase: "crimson-otter-harbor",
        preview: %{summary: "ready"},
        expires_at: DateTime.add(DateTime.utc_now(), 300, :second)
      },
      overrides
    )
  end

  defp insert!(overrides \\ %{}) do
    %PendingConfirmation{}
    |> PendingConfirmation.insert_changeset(valid_attrs(overrides))
    |> Repo.insert!()
  end

  describe "insert_changeset/2" do
    test "inserts a row with the required fields populated" do
      row = insert!() |> then(&Repo.reload!/1)

      assert row.session_id == "session-abc"
      assert row.tool_name == "approve_draft"
      assert row.params_hash == String.duplicate("a", 64)
      assert row.echo_phrase == "crimson-otter-harbor"
      assert row.preview == %{"summary" => "ready"}
      assert row.consumed_at == nil
    end

    test "requires session_id, tool_name, params_hash, echo_phrase, expires_at" do
      cs =
        PendingConfirmation.insert_changeset(
          %PendingConfirmation{},
          %{preview: %{}}
        )

      errors = errors_on(cs)
      assert errors[:session_id]
      assert errors[:tool_name]
      assert errors[:params_hash]
      assert errors[:echo_phrase]
      assert errors[:expires_at]
    end
  end

  describe "partial unique index on (session_id, echo_phrase)" do
    test "prevents two live rows with the same (session, phrase)" do
      _ = insert!()

      cs =
        PendingConfirmation.insert_changeset(
          %PendingConfirmation{},
          valid_attrs(%{params_hash: String.duplicate("b", 64)})
        )

      assert {:error, changeset} = Repo.insert(cs)
      # The unique_constraint attaches the message to one of the
      # two columns in the index tuple; Ecto reports it under the
      # field that triggered the check, which for this index is
      # session_id.
      assert changeset.errors[:session_id] || changeset.errors[:echo_phrase]
    end

    test "permits reuse of the (session, phrase) pair after the first row is consumed" do
      row = insert!()

      row
      |> Ecto.Changeset.change(consumed_at: DateTime.utc_now())
      |> Repo.update!()

      # A fresh live row with the same (session, phrase) should
      # now succeed because the partial-unique predicate only
      # looks at unconsumed rows.
      fresh = insert!(%{params_hash: String.duplicate("c", 64)})
      assert fresh.id != row.id
    end
  end
end
