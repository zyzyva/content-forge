defmodule ContentForgeWeb.ProductController do
  use ContentForgeWeb, :controller
  alias ContentForge.Products

  action_fallback ContentForgeWeb.FallbackController

  def index(conn, _params) do
    products = Products.list_products()
    render(conn, :index, products: products)
  end

  def create(conn, %{"product" => product_params}) do
    case Products.create_product(product_params) do
      {:ok, product} ->
        conn
        |> put_status(:created)
        |> render(:show, product: product)

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render(:error, message: format_changeset_errors(changeset))
    end
  end

  def show(conn, %{"id" => id}) do
    case Products.get_product(id) do
      nil -> {:error, :not_found}
      product -> render(conn, :show, product: product)
    end
  end

  def update(conn, %{"id" => id, "product" => product_params}) do
    case Products.get_product(id) do
      nil ->
        {:error, :not_found}

      product ->
        case Products.update_product(product, product_params) do
          {:ok, product} ->
            render(conn, :show, product: product)

          {:error, %Ecto.Changeset{} = changeset} ->
            conn
            |> put_status(:unprocessable_entity)
            |> render(:error, message: format_changeset_errors(changeset))
        end
    end
  end

  def delete(conn, %{"id" => id}) do
    case Products.get_product(id) do
      nil ->
        {:error, :not_found}

      product ->
        case Products.delete_product(product) do
          {:ok, _} ->
            send_resp(conn, :no_content, "")

          {:error, _} ->
            conn
            |> put_status(:internal_server_error)
            |> json(%{error: "deletion failed"})
        end
    end
  end

  defp format_changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        Keyword.get(opts, String.to_existing_atom(key), key)
      end)
    end)
  end
end
