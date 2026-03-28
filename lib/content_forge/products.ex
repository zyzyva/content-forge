defmodule ContentForge.Products do
  @moduledoc """
  The Products context handles CRUD operations for products, blog webhooks,
  snapshots, competitor accounts, and competitor intel.
  """
  import Ecto.Query
  alias ContentForge.Repo
  alias ContentForge.Products.Product
  alias ContentForge.Products.BlogWebhook
  alias ContentForge.Products.ProductSnapshot
  alias ContentForge.Products.CompetitorAccount
  alias ContentForge.Products.CompetitorPost
  alias ContentForge.Products.CompetitorIntel

  # Product CRUD

  def list_products do
    Repo.all(Product)
  end

  def get_product!(id), do: Repo.get!(Product, id)

  def get_product(id), do: Repo.get(Product, id)

  def create_product(attrs \\ %{}) do
    %Product{}
    |> Product.changeset(attrs)
    |> Repo.insert()
  end

  def update_product(%Product{} = product, attrs) do
    product
    |> Product.changeset(attrs)
    |> Repo.update()
  end

  def delete_product(%Product{} = product) do
    Repo.delete(product)
  end

  # BlogWebhook CRUD

  def list_blog_webhooks do
    Repo.all(BlogWebhook)
  end

  def list_blog_webhooks_for_product(product_id) do
    BlogWebhook
    |> where(product_id: ^product_id)
    |> Repo.all()
  end

  def get_blog_webhook!(id), do: Repo.get!(BlogWebhook, id)

  def get_blog_webhook(id), do: Repo.get(BlogWebhook, id)

  def create_blog_webhook(attrs \\ %{}) do
    %BlogWebhook{}
    |> BlogWebhook.changeset(attrs)
    |> Repo.insert()
  end

  def update_blog_webhook(%BlogWebhook{} = webhook, attrs) do
    webhook
    |> BlogWebhook.changeset(attrs)
    |> Repo.update()
  end

  def delete_blog_webhook(%BlogWebhook{} = webhook) do
    Repo.delete(webhook)
  end

  # ProductSnapshot CRUD

  def list_product_snapshots do
    Repo.all(ProductSnapshot)
  end

  def list_product_snapshots_for_product(product_id) do
    ProductSnapshot
    |> where(product_id: ^product_id)
    |> order_by(desc: :inserted_at)
    |> Repo.all()
  end

  def get_product_snapshot!(id), do: Repo.get!(ProductSnapshot, id)

  def get_product_snapshot(id), do: Repo.get(ProductSnapshot, id)

  def get_latest_snapshot_for_product(product_id, type) do
    ProductSnapshot
    |> where(product_id: ^product_id, snapshot_type: ^type)
    |> order_by(desc: :inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  def create_product_snapshot(attrs \\ %{}) do
    %ProductSnapshot{}
    |> ProductSnapshot.changeset(attrs)
    |> Repo.insert()
  end

  def delete_product_snapshot(%ProductSnapshot{} = snapshot) do
    Repo.delete(snapshot)
  end

  # CompetitorAccount CRUD

  def list_competitor_accounts do
    Repo.all(CompetitorAccount)
  end

  def list_competitor_accounts_for_product(product_id) do
    CompetitorAccount
    |> where(product_id: ^product_id)
    |> Repo.all()
  end

  def list_active_competitor_accounts_for_product(product_id) do
    CompetitorAccount
    |> where(product_id: ^product_id, active: true)
    |> Repo.all()
  end

  def get_competitor_account!(id), do: Repo.get!(CompetitorAccount, id)

  def get_competitor_account(id), do: Repo.get(CompetitorAccount, id)

  def create_competitor_account(attrs \\ %{}) do
    %CompetitorAccount{}
    |> CompetitorAccount.changeset(attrs)
    |> Repo.insert()
  end

  def update_competitor_account(%CompetitorAccount{} = account, attrs) do
    account
    |> CompetitorAccount.changeset(attrs)
    |> Repo.update()
  end

  def delete_competitor_account(%CompetitorAccount{} = account) do
    Repo.delete(account)
  end

  # CompetitorPost CRUD

  def list_competitor_posts_for_account(account_id) do
    CompetitorPost
    |> where(competitor_account_id: ^account_id)
    |> order_by(desc: :posted_at)
    |> Repo.all()
  end

  def list_top_competitor_posts_for_product(product_id, max \\ 10) do
    account_ids =
      product_id
      |> list_active_competitor_accounts_for_product()
      |> Enum.map(& &1.id)

    CompetitorPost
    |> where(competitor_account_id: ^account_ids)
    |> order_by(desc: :engagement_score)
    |> limit(^max)
    |> Repo.all()
  end

  def create_competitor_post(attrs \\ %{}) do
    %CompetitorPost{}
    |> CompetitorPost.changeset(attrs)
    |> Repo.insert()
  end

  def delete_competitor_posts_for_account(account_id) do
    CompetitorPost
    |> where(competitor_account_id: ^account_id)
    |> Repo.delete_all()
  end

  # CompetitorIntel CRUD

  def list_competitor_intel_for_product(product_id) do
    CompetitorIntel
    |> where(product_id: ^product_id)
    |> order_by(desc: :inserted_at)
    |> Repo.all()
  end

  def get_latest_competitor_intel_for_product(product_id) do
    CompetitorIntel
    |> where(product_id: ^product_id)
    |> order_by(desc: :inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  def create_competitor_intel(attrs \\ %{}) do
    %CompetitorIntel{}
    |> CompetitorIntel.changeset(attrs)
    |> Repo.insert()
  end
end
