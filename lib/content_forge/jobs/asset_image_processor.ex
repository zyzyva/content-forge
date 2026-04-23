defmodule ContentForge.Jobs.AssetImageProcessor do
  @moduledoc """
  Oban worker that routes a pending `ProductAsset` (image) through Media
  Forge for EXIF strip, autorotate, thumbnail, and probe.

  The register endpoint (13.1b) enqueues this job. The Media Forge
  dispatch is wired under 13.1d; this module ships as a no-op placeholder
  with just enough surface to be enqueued and introspected by
  `assert_enqueued` in tests.
  """

  use Oban.Worker, queue: :content_generation, max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"asset_id" => _asset_id}}) do
    # Intentional no-op until 13.1d wires the Media Forge call.
    :ok
  end
end
