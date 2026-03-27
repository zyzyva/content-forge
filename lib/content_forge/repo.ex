defmodule ContentForge.Repo do
  use Ecto.Repo,
    otp_app: :content_forge,
    adapter: Ecto.Adapters.Postgres
end
