defmodule ContentForge.Metrics.ClipFlag do
  @moduledoc """
  Schema for flagging high-engagement segments in videos for clip extraction.
  Parses YouTube retention curves to identify viral moments.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "clip_flags" do
    field :video_id, :binary_id
    field :video_platform_id, :string
    field :platform, :string

    # High engagement segment
    field :start_seconds, :integer
    field :end_seconds, :integer
    field :suggested_title, :string

    # Engagement data
    field :segment_views, :integer
    field :segment_engagement_rate, :float

    # Source data
    field :retention_curve, :map
    field :engagement_spike_data, :map

    timestamps type: :utc_datetime
  end

  def changeset(clip_flag, attrs) do
    clip_flag
    |> cast(attrs, [
      :video_id,
      :video_platform_id,
      :platform,
      :start_seconds,
      :end_seconds,
      :suggested_title,
      :segment_views,
      :segment_engagement_rate,
      :retention_curve,
      :engagement_spike_data
    ])
    |> validate_required([:video_id, :video_platform_id, :platform, :start_seconds, :end_seconds])
    |> validate_inclusion(:platform, ~w(youtube tiktok))
    |> validate_number(:start_seconds, greater_than_or_equal_to: 0)
    |> validate_number(:end_seconds, greater_than: 0)
    |> validate_that(:end_seconds, :start_seconds, &(&2 > &1))
    |> generate_suggested_title()
  end

  defp validate_that(changeset, field, other_field, comparator) do
    validate_change(changeset, field, fn ^field, value ->
      other_value = get_field(changeset, other_field)

      if other_value != nil and not comparator.(other_value, value) do
        [{field, "must be greater than #{other_field}"}]
      else
        []
      end
    end)
  end

  defp generate_suggested_title(changeset) do
    if get_change(changeset, :suggested_title) do
      changeset
    else
      # Auto-generate a title based on segment position
      start_sec =
        get_change(changeset, :start_seconds) || get_field(changeset, :start_seconds) || 0

      minutes = div(start_sec, 60)
      seconds = rem(start_sec, 60)
      position = if minutes > 0, do: "#{minutes}m#{seconds}s", else: "#{seconds}s"

      title = "Clip at #{position}"
      put_change(changeset, :suggested_title, title)
    end
  end

  @doc """
  Parse YouTube retention curve data and identify high-engagement spikes.
  retention_curve: map with "data" key containing list of {seconds, percentage} tuples
  """
  def from_youtube_retention(video_id, platform_id, retention_curve) do
    case extract_spikes(retention_curve) do
      [] ->
        {:error, :no_spikes_found}

      spikes ->
        flags =
          Enum.map(spikes, fn {start, end_sec, views, rate} ->
            spike_type = if rate != nil, do: detect_spike_type(rate), else: :notable

            %__MODULE__{}
            |> changeset(%{
              video_id: video_id,
              video_platform_id: platform_id,
              platform: "youtube",
              start_seconds: start,
              end_seconds: end_sec,
              segment_views: views,
              segment_engagement_rate: rate,
              retention_curve: retention_curve,
              engagement_spike_data: %{
                spike_type: spike_type,
                detected_at: DateTime.utc_now()
              }
            })
          end)

        {:ok, flags}
    end
  end

  # Extract spikes where engagement rate is significantly higher than average
  defp extract_spikes(%{"data" => data}) when is_list(data) do
    # Parse retention data: [{"time", "percentage"}, ...]
    parsed =
      Enum.map(data, fn
        %{"time" => t, "value" => v} -> {String.to_integer(t), String.to_float(v)}
        {t, v} when is_binary(t) -> {String.to_integer(t), String.to_float(v)}
        {t, v} -> {t, v}
      end)

    if length(parsed) < 5 do
      []
    else
      # Calculate average retention
      values = Enum.map(parsed, fn {_, v} -> v end)
      avg = Enum.sum(values) / length(values)

      # Find segments where retention drops significantly (indicates engagement/action)
      # Or where retention stays high (viral content)
      spikes = find_spikes(parsed, avg)
      spikes
    end
  end

  defp extract_spikes(_), do: []

  defp find_spikes(data, avg_retention) do
    # Find points where there's significant deviation
    data
    |> Enum.chunk_every(3, 1, :discard)
    |> Enum.filter(fn chunk ->
      {_times, values} = Enum.unzip(chunk)
      chunk_avg = Enum.sum(values) / length(values)
      # Spike if chunk is significantly above average
      chunk_avg > avg_retention * 1.2
    end)
    |> Enum.map(fn chunk ->
      {times, _} = Enum.unzip(chunk)
      start = List.first(times)
      ending = List.last(times)
      # Views and rate to be filled by platform API
      {start, ending, nil, nil}
    end)
  end

  defp detect_spike_type(rate) when rate > 10, do: :viral
  defp detect_spike_type(rate) when rate > 5, do: :high_engagement
  defp detect_spike_type(_), do: :notable
end
