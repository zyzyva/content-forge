defmodule ContentForge.ProductAssets.AcceptedContentTypes do
  @moduledoc """
  Single source of truth for the MIME types Content Forge accepts
  on any asset-upload path.

  Two callers use this module today:

    * `ContentForgeWeb.ProductAssetController` (13.1b) validates
      incoming `content_type` params against `list/0` before
      presigning or registering an asset.
    * `ContentForge.OpenClawTools.CreateUploadLink` (16.3b) uses
      `allowed?/1` to refuse an unsupported content type before
      reaching the storage adapter.

  Keeping the allow-list here prevents divergence between the
  operator-dashboard flow and the agent-tool flow. Adding a new
  MIME type means touching exactly one module.
  """

  @image_content_types ~w(image/jpeg image/png image/webp image/heic)
  @video_content_types ~w(video/mp4 video/quicktime video/x-m4v)
  @allowed_content_types @image_content_types ++ @video_content_types

  @doc "Every accepted content type (images + videos)."
  @spec list() :: [String.t()]
  def list, do: @allowed_content_types

  @doc "Accepted image content types only."
  @spec image_list() :: [String.t()]
  def image_list, do: @image_content_types

  @doc "Accepted video content types only."
  @spec video_list() :: [String.t()]
  def video_list, do: @video_content_types

  @doc "Returns true when `content_type` is on the combined allow-list."
  @spec allowed?(term()) :: boolean()
  def allowed?(content_type) when is_binary(content_type),
    do: content_type in @allowed_content_types

  def allowed?(_), do: false
end
