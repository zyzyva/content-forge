defmodule ContentForgeWeb.Live.Dashboard.Products.ListLive do
  require Logger

  @moduledoc """
  LiveView for listing all products with quick-add form.
  """
  use ContentForgeWeb, :live_view
  alias ContentForge.Products

  @impl true
  def mount(_params, _session, socket) do
    products = Products.list_products()
    {:ok, assign(socket, products: products, search: "", form: to_form(%{}))}
  end

  @impl true
  def handle_event("search", %{"search" => search}, socket) do
    {:noreply, assign(socket, search: search)}
  end

  @impl true
  def handle_event("add_product", %{"name" => name, "voice_profile" => voice_profile}, socket) do
    case Products.create_product(%{name: name, voice_profile: voice_profile}) do
      {:ok, product} ->
        Logger.info("Created product: #{product.id}")
        {:noreply, assign(socket, products: Products.list_products(), form: to_form(%{}))}

      {:error, changeset} ->
        Logger.error("Failed to create product: #{inspect(changeset.errors)}")
        {:noreply, put_flash(socket, :error, "Failed to create product")}
    end
  end

  @impl true
  def handle_event("delete_product", %{"id" => id}, socket) do
    product = Products.get_product!(id)

    case Products.delete_product(product) do
      {:ok, _} ->
        Logger.info("Deleted product: #{id}")
        {:noreply, assign(socket, products: Products.list_products())}

      {:error, changeset} ->
        Logger.error("Failed to delete product: #{inspect(changeset.errors)}")
        {:noreply, put_flash(socket, :error, "Failed to delete product")}
    end
  end

  defp filtered_products(products, "") do
    products
  end

  defp filtered_products(products, search) do
    search_lower = String.downcase(search)
    Enum.filter(products, fn p -> String.contains?(String.downcase(p.name), search_lower) end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex flex-col sm:flex-row justify-between items-start sm:items-center gap-4">
        <div>
          <h1 class="text-2xl font-bold">Products</h1>
          <p class="text-base-content/70">Manage your content products</p>
        </div>
      </div>
      
    <!-- Quick Add Form -->
      <div class="card bg-base-200">
        <div class="card-body">
          <h2 class="card-title text-base">Quick Add Product</h2>
          <form phx-submit="add_product" class="flex flex-col sm:flex-row gap-4">
            <input
              type="text"
              name="name"
              placeholder="Product name"
              class="input input-bordered flex-1"
              required
            />
            <input
              type="text"
              name="voice_profile"
              placeholder="Voice profile (e.g., professional, casual)"
              class="input input-bordered flex-1"
              required
            />
            <button type="submit" class="btn btn-primary">
              Add Product
            </button>
          </form>
        </div>
      </div>
      
    <!-- Search -->
      <div class="form-control">
        <input
          type="text"
          name="search"
          placeholder="Search products..."
          class="input input-bordered w-full"
          phx-input="search"
          value={@search}
        />
      </div>
      
    <!-- Products Grid -->
      <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
        <div
          :for={product <- filtered_products(@products, @search)}
          class="card bg-base-200 hover:bg-base-300 transition-colors"
        >
          <div class="card-body">
            <div class="flex justify-between items-start">
              <div>
                <h3 class="font-semibold text-lg">
                  <.link navigate={~p"/dashboard/products/#{product.id}"} class="hover:underline">
                    {product.name}
                  </.link>
                </h3>
                <p class="text-sm text-base-content/70">{product.voice_profile}</p>
              </div>
              <button
                phx-click="delete_product"
                phx-value-id={product.id}
                class="btn btn-ghost btn-sm btn-circle text-error"
                onclick="return confirm('Delete this product?')"
              >
                <.icon name="hero-trash" class="size-4" />
              </button>
            </div>

            <div class="flex gap-4 mt-2 text-sm">
              <span class="text-base-content/70">
                <.icon name="hero-link" class="size-3 inline" />
                {if product.site_url, do: "Site configured", else: "No site"}
              </span>
              <span class="text-base-content/70">
                <.icon name="hero-code-bracket" class="size-3 inline" />
                {if product.repo_url, do: "Repo configured", else: "No repo"}
              </span>
            </div>

            <div class="card-actions justify-end mt-4">
              <.link navigate={~p"/dashboard/products/#{product.id}"} class="btn btn-sm btn-primary">
                View Details
              </.link>
            </div>
          </div>
        </div>
      </div>

      <div
        :if={length(filtered_products(@products, @search)) == 0}
        class="text-center py-12 text-base-content/70"
      >
        <.icon name="hero-folder" class="size-12 mx-auto mb-4 opacity-50" />
        <p>No products found</p>
      </div>
    </div>
    """
  end
end
