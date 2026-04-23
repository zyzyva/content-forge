defmodule ContentForgeWeb.CompetitorController do
  use ContentForgeWeb, :controller

  alias ContentForge.Products
  alias ContentForge.Products.CompetitorAccount

  action_fallback ContentForgeWeb.FallbackController

  def index(conn, %{"product_id" => product_id}) do
    competitors = Products.list_competitor_accounts_for_product(product_id)
    render(conn, :index, competitors: competitors)
  end

  def create(conn, %{"product_id" => product_id, "competitor" => competitor_params}) do
    params = Map.put(competitor_params, "product_id", product_id)

    with {:ok, %CompetitorAccount{} = competitor} <- Products.create_competitor_account(params) do
      conn
      |> put_status(:created)
      |> render(:show, competitor: competitor)
    end
  end

  def show(conn, %{"product_id" => _product_id, "id" => id}) do
    competitor = Products.get_competitor_account!(id)
    render(conn, :show, competitor: competitor)
  end

  def update(conn, %{"product_id" => _product_id, "id" => id, "competitor" => competitor_params}) do
    competitor = Products.get_competitor_account!(id)

    with {:ok, %CompetitorAccount{} = competitor} <-
           Products.update_competitor_account(competitor, competitor_params) do
      render(conn, :show, competitor: competitor)
    end
  end

  def delete(conn, %{"product_id" => _product_id, "id" => id}) do
    competitor = Products.get_competitor_account!(id)

    with {:ok, %CompetitorAccount{}} <- Products.delete_competitor_account(competitor) do
      send_resp(conn, :no_content, "")
    end
  end
end

defmodule ContentForgeWeb.CompetitorJSON do
  alias ContentForge.Products.CompetitorAccount

  def index(%{competitors: competitors}) do
    %{data: Enum.map(competitors, &competitor/1)}
  end

  def show(%{competitor: competitor}) do
    %{data: competitor(competitor)}
  end

  defp competitor(%CompetitorAccount{} = c) do
    %{
      id: c.id,
      product_id: c.product_id,
      platform: c.platform,
      handle: c.handle,
      url: c.url,
      active: c.active,
      inserted_at: c.inserted_at,
      updated_at: c.updated_at
    }
  end
end
