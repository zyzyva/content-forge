defmodule ContentForgeWeb.ProductJSON do
  alias ContentForge.Products.Product

  def index(%{products: products}) do
    %{data: Enum.map(products, &data/1)}
  end

  def show(%{product: product}), do: %{data: data(product)}

  defp data(%Product{} = product) do
    %{
      id: product.id,
      name: product.name,
      repo_url: product.repo_url,
      site_url: product.site_url,
      voice_profile: product.voice_profile,
      publishing_targets: product.publishing_targets,
      inserted_at: product.inserted_at,
      updated_at: product.updated_at
    }
  end
end
