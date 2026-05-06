defmodule ContentForge.Products.BlogWebhook do
  @moduledoc """
  Per-product blog publishing webhook.

  Carries the receiver URL + HMAC secret + the platform-specific
  credentials needed for the receiver to fan out to a CMS
  (WordPress + Generic today; the receiver dropped Ghost in
  feature/cms-handlers).

  ## Note on credentials (plaintext at rest)

  As of this commit, `wp_app_password` and `generic_bearer_token`
  / `generic_basic_password` are stored in the database **as
  plaintext**. The same is intended for `ghost_admin_api_key`
  if/when Ghost lands again. Operators with database access can
  read them.

  This is acceptable for a single-operator, runway-stage
  deployment but is documented here as an explicit known gap.
  Encryption at rest (Cloak.Ecto or equivalent vault-keyed
  field encryption) is a tracked follow-up; until that lands,
  treat these columns the same way you would treat any secrets
  table - restrict DB access, do not export to logs / backups
  unredacted, and rotate any value that ever leaks.

  The `BlogPublisher` job already handles in-flight redaction
  for log lines, but at-rest exposure is the unhandled half.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "blog_webhooks" do
    field :url, :string
    field :hmac_secret, :string
    field :active, :boolean, default: true

    # Platform: which handler to use on the receiver
    field :platform, :string, default: "generic"

    # WordPress credentials
    field :wp_site_url, :string
    field :wp_username, :string
    field :wp_app_password, :string

    # Generic webhook credentials
    field :generic_auth_type, :string, default: "none"
    field :generic_bearer_token, :string
    field :generic_basic_username, :string
    field :generic_basic_password, :string

    belongs_to :product, ContentForge.Products.Product

    timestamps type: :utc_datetime
  end

  @platforms ["wordpress", "generic"]
  @auth_types ["none", "bearer", "basic"]

  def changeset(webhook, attrs) do
    webhook
    |> cast(attrs, [
      :url,
      :hmac_secret,
      :active,
      :product_id,
      :platform,
      :wp_site_url,
      :wp_username,
      :wp_app_password,
      :generic_auth_type,
      :generic_bearer_token,
      :generic_basic_username,
      :generic_basic_password
    ])
    |> validate_required([:url, :product_id, :platform])
    |> validate_format(:url, ~r/^https?:\/\/.*$/)
    |> validate_inclusion(:platform, @platforms)
    |> validate_inclusion(:generic_auth_type, @auth_types)
    |> maybe_validate_wordpress()
  end

  # `get_field/2` (not `get_change/2`) so the WordPress-required
  # validations still run on UPDATE when `:platform` is unchanged.
  # An UPDATE that casts `%{wp_site_url: nil}` against an existing
  # WordPress row must fail validation; with `get_change/2` the
  # platform key was nil-on-update and the entire branch
  # short-circuited, letting the caller blank out a required field.
  defp maybe_validate_wordpress(changeset) do
    validate_for_platform(get_field(changeset, :platform), changeset)
  end

  defp validate_for_platform("wordpress", changeset) do
    changeset
    |> validate_required([:wp_site_url, :wp_username, :wp_app_password],
      message: "required for WordPress platform"
    )
    |> validate_format(:wp_site_url, ~r/^https?:\/\/.*$/, message: "must be a valid URL")
  end

  defp validate_for_platform(_other, changeset), do: changeset

  @doc """
  Returns the CMS metadata map for this webhook to include in the
  webhook payload sent to the receiver.
  """
  def cms_metadata(%__MODULE__{} = webhook) do
    Map.new()
    |> maybe_put("platform", webhook.platform)
    |> maybe_put("wp_site_url", webhook.wp_site_url)
    |> maybe_put("wp_username", webhook.wp_username)
    |> maybe_put("wp_app_password", webhook.wp_app_password)
    |> maybe_put("generic_auth_type", webhook.generic_auth_type)
    |> maybe_put("generic_bearer_token", webhook.generic_bearer_token)
    |> maybe_put("generic_basic_username", webhook.generic_basic_username)
    |> maybe_put("generic_basic_password", webhook.generic_basic_password)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc """
  Platform display name.
  """
  def platform_name("wordpress"), do: "WordPress"
  def platform_name("generic"), do: "Generic Webhook"
  def platform_name(_), do: "Unknown"
end
