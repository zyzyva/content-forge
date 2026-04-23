defmodule ContentForge.Products.ProductMemory do
  @moduledoc """
  Conversation-derived note attached to a product.

  Rows are written by the OpenClaw `record_memory` tool (16.3d)
  when the agent decides a fragment of the current conversation
  is worth persisting (a client preference, a seasonal pattern
  the user mentioned, a past job). The tool supplies
  `session_id`, `channel`, and `sender_identity` from the
  invocation `ctx` so audit trails can reconstruct where each
  memory came from.

  Content is free text bounded at 2000 characters; tags are a
  small array of 1..40-character strings (trimmed + lowercased
  by the tool layer). PII classification and redaction is NOT
  handled here - the Feature 12 spec notes that sensitive-content
  flagging is deferred until a classifier is available.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @content_min 1
  @content_max 2000
  @tag_min 1
  @tag_max 40

  schema "product_memories" do
    field :session_id, :string
    field :channel, :string
    field :sender_identity, :string
    field :content, :string
    field :tags, {:array, :string}, default: []

    belongs_to :product, ContentForge.Products.Product

    timestamps(type: :utc_datetime)
  end

  @required ~w(product_id session_id channel content)a
  @optional ~w(sender_identity tags)a

  @doc "Changeset for `Products.create_memory/1`."
  def changeset(memory, attrs) do
    memory
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_length(:content, min: @content_min, max: @content_max)
    |> validate_length(:session_id, min: 1, max: 255)
    |> validate_length(:channel, min: 1, max: 40)
    |> validate_tags()
    |> foreign_key_constraint(:product_id)
  end

  defp validate_tags(changeset) do
    validate_change(changeset, :tags, fn :tags, tags ->
      case bad_tag(tags) do
        nil -> []
        reason -> [tags: reason]
      end
    end)
  end

  defp bad_tag(tags) when is_list(tags) do
    Enum.find_value(tags, fn
      tag when is_binary(tag) ->
        cond do
          byte_size(tag) < @tag_min -> "tag must be at least #{@tag_min} character"
          byte_size(tag) > @tag_max -> "tag must be at most #{@tag_max} characters"
          true -> nil
        end

      _ ->
        "tags must be strings"
    end)
  end

  defp bad_tag(_), do: "tags must be a list of strings"
end
