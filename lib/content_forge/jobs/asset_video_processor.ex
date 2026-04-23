defmodule ContentForge.Jobs.AssetVideoProcessor do
  @moduledoc """
  Oban worker that routes a pending `ProductAsset` (video) through Media
  Forge for probe, normalize, and poster-frame generation.

  The register endpoint (13.1b) enqueues this job. The Media Forge
  dispatch is wired under 13.1e; this module ships as a no-op placeholder
  with just enough surface to be enqueued and introspected by
  `assert_enqueued` in tests.
  """

  use Oban.Worker, queue: :content_generation, max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"asset_id" => _asset_id}}) do
    # Intentional no-op until 13.1e wires the Media Forge call.
    :ok
  end
end
