defmodule ContentForgeWeb.ToolActivityJSON do
  alias ContentForge.Products.Product
  alias ContentForgeWeb.ToolActivityController

  def index(%{events: events, product: %Product{} = product, filters: filters}) do
    %{
      data: %{
        product_id: product.id,
        product_name: product.name,
        filters: filters,
        events: Enum.map(events, &ToolActivityController.serialize_event/1),
        total_count: length(events)
      }
    }
  end
end
