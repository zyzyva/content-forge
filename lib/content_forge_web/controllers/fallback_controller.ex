defmodule ContentForgeWeb.FallbackController do
  use ContentForgeWeb, :controller

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(html: ContentForgeWeb.ErrorJSON)
    |> render(:error, message: format_changeset_errors(changeset))
  end

  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> put_view(json: ContentForgeWeb.ErrorJSON, html: ContentForgeWeb.ErrorJSON)
    |> render(:"404")
  end

  defp format_changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        Keyword.get(opts, String.to_existing_atom(key), key)
      end)
    end)
  end
end
