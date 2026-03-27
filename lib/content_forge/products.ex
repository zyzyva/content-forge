defmodule ContentForge.Products do
  @moduledoc """
  The Products context handles CRUD operations for products and blog webhooks.
  """
  import Ecto.Query
  alias ContentForge.Repo
  alias ContentForge.Products.Product
  alias ContentForge.Products.BlogWebhook

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
end
