defmodule ContentForgeWeb.PageController do
  use ContentForgeWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
