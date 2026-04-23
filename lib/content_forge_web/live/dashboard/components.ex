defmodule ContentForgeWeb.Live.Dashboard.Components do
  @moduledoc """
  Shared LiveView components for the dashboard.
  """
  use Phoenix.Component

  import Phoenix.Component
  import ContentForgeWeb.CoreComponents

  attr :status, :string, required: true
  attr :class, :string, default: ""

  def status_badge(assigns) do
    status_classes =
      case assigns.status do
        "draft" -> "badge-neutral"
        "ranked" -> "badge-warning"
        "approved" -> "badge-info"
        "rejected" -> "badge-error"
        "blocked" -> "badge-error"
        "published" -> "badge-success"
        "pending" -> "badge-neutral"
        "completed" -> "badge-success"
        "failed" -> "badge-error"
        "paused" -> "badge-warning"
        _ -> "badge-neutral"
      end

    assigns = assign(assigns, :status_classes, status_classes)

    ~H"""
    <span class={["badge", @status_classes, @class]}>
      {String.upcase(@status)}
    </span>
    """
  end

  attr :score, :any, required: true

  def score_display(assigns) do
    score = assigns.score * 1.0

    score_class =
      cond do
        score >= 8.0 -> "text-success"
        score >= 5.0 -> "text-warning"
        true -> "text-error"
      end

    assigns = assigns |> assign(:score_class, score_class) |> assign(:score, score)

    ~H"""
    <span class={["font-mono font-semibold", @score_class]}>
      {Float.round(@score, 1)}
    </span>
    """
  end

  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  attr :icon, :string, default: "hero-folder"
  attr :href, :string, default: nil

  def card_link(assigns) do
    ~H"""
    <a href={@href} class="card bg-base-200 hover:bg-base-300 transition-colors cursor-pointer">
      <div class="card-body">
        <div class="flex items-center gap-3">
          <.icon name={@icon} class="size-6 text-primary" />
          <div>
            <h3 class="font-semibold">{@title}</h3>
            <p :if={@subtitle} class="text-sm text-base-content/70">{@subtitle}</p>
          </div>
        </div>
      </div>
    </a>
    """
  end

  attr :count, :integer, required: true
  attr :label, :string, required: true

  def stat_card(assigns) do
    ~H"""
    <div class="stat bg-base-200">
      <div class="stat-title text-xs">{@label}</div>
      <div class="stat-value text-2xl">{@count}</div>
    </div>
    """
  end

  def format_datetime(nil), do: "—"

  def format_datetime(%DateTime{} = dt) do
    "#{dt.year}-#{pad(dt.month)}-#{pad(dt.day)} #{pad(dt.hour)}:#{pad(dt.minute)}"
  end

  def format_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> format_datetime(dt)
      _ -> str
    end
  end

  defp pad(n) when n < 10, do: "0#{n}"
  defp pad(n), do: Integer.to_string(n)
end
