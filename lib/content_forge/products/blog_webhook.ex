defmodule ContentForge.Products.BlogWebhook do
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

  defp maybe_validate_wordpress(changeset) do
    if get_change(changeset, :platform) == "wordpress" do
      changeset
      |> validate_required([:wp_site_url, :wp_username, :wp_app_password],
        message: "required for WordPress platform"
      )
      |> validate_format(:wp_site_url, ~r/^https?:\/\/.*$/, message: "must be a valid URL")
    else
      changeset
    end
  end

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