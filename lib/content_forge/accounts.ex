defmodule ContentForge.Accounts do
  @moduledoc """
  The Accounts context handles API key management.
  """
  import Ecto.Query
  alias ContentForge.Repo
  alias ContentForge.Accounts.ApiKey

  def list_api_keys do
    Repo.all(ApiKey)
  end

  def get_api_key!(id), do: Repo.get!(ApiKey, id)

  def get_active_api_key_by_key(key) do
    ApiKey
    |> where(key: ^key, active: true)
    |> Repo.one()
  end

  def create_api_key(attrs \\ %{}) do
    %ApiKey{}
    |> ApiKey.changeset(attrs)
    |> Repo.insert()
  end

  def update_api_key(%ApiKey{} = api_key, attrs) do
    api_key
    |> ApiKey.changeset(attrs)
    |> Repo.update()
  end

  def delete_api_key(%ApiKey{} = api_key) do
    Repo.delete(api_key)
  end

  def generate_api_key do
    :crypto.strong_rand_bytes(32) |> Base.encode64(padding: false)
  end
end
