defmodule ContentForge.Repo.Migrations.AddCmsFieldsToBlogWebhooks do
  use Ecto.Migration

  def change do
    alter table(:blog_webhooks) do
      # Platform: which handler to use on the receiver
      add :platform, :string, default: "generic"

      # WordPress credentials
      add :wp_site_url, :string
      add :wp_username, :string
      add :wp_app_password, :string

      # Generic webhook credentials
      add :generic_auth_type, :string, default: "none"
      add :generic_bearer_token, :string
      add :generic_basic_username, :string
      add :generic_basic_password, :string
    end


  end
end