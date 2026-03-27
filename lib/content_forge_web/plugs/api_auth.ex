defmodule ContentForgeWeb.Plugs.ApiAuth do
  @moduledoc """
  Plug for bearer token authentication against API keys.
  """
  import Plug.Conn
  import Phoenix.Controller
  alias ContentForge.Accounts

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         %{} = api_key <- Accounts.get_active_api_key_by_key(token) do
      assign(conn, :api_key, api_key)
    else
      _ ->
        conn
        |> put_status(:unauthorized)
        |> put_view(html: ContentForgeWeb.ErrorJSON)
        |> render(:error, message: "Unauthorized")
        |> halt()
    end
  end

  def render_error(conn, message) do
    conn
    |> put_status(:unauthorized)
    |> put_view(html: ContentForgeWeb.ErrorJSON)
    |> render(:error, message: message)
    |> halt()
  end
end
