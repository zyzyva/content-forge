defmodule ContentForge.Jobs.SiteCrawler do
  @moduledoc """
  Oban job that crawls up to N pages from a site URL, extracts text content,
  headings, metadata, and captures screenshots. Stores everything in R2.
  """
  use Oban.Worker, queue: :ingestion, max_attempts: 3

  require Logger

  alias ContentForge.Products
  alias ContentForge.Storage

  @max_pages Application.compile_env(:content_forge, :max_crawl_pages, 10)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"product_id" => product_id, "site_url" => site_url}}) do
    Logger.info("Starting site crawl for product #{product_id} at #{site_url}")

    with {:ok, _product} <- fetch_product(product_id),
         {:ok, pages} <- crawl_pages(site_url),
         {:ok, r2_keys} <- store_in_r2(product_id, pages),
         {:ok, _snapshot} <- create_snapshot(product_id, r2_keys, pages) do
      Logger.info(
        "Site crawl completed for product #{product_id}, crawled #{length(pages)} pages"
      )

      :ok
    else
      {:error, reason} ->
        Logger.error("Site crawl failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp fetch_product(product_id) do
    case Products.get_product(product_id) do
      nil -> {:error, :not_found}
      product -> {:ok, product}
    end
  end

  defp crawl_pages(site_url) do
    Logger.info("Crawling site: #{site_url}")

    base_url = URI.parse(site_url)

    with {:ok, %{body: body, title: title, meta: meta}} <- fetch_page(site_url) do
      pages = [%{url: site_url, content: body, title: title, meta: meta}]

      links = extract_links(body, base_url)
      valid_links = Enum.take(links |> Enum.reject(&is_external?(&1, base_url)), @max_pages - 1)

      Logger.info("Found #{length(valid_links)} additional links to crawl")

      additional_pages =
        valid_links
        |> Enum.map(fn link ->
          case fetch_page(link) do
            {:ok, %{body: body, title: title, meta: meta}} ->
              %{url: link, content: body, title: title, meta: meta}

            {:error, reason} ->
              Logger.warning("Failed to fetch #{link}: #{inspect(reason)}")
              nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      {:ok, pages ++ additional_pages}
    end
  end

  defp fetch_page(url) do
    case Req.get(url, receive_timeout: 30_000) do
      {:ok, response} ->
        body = extract_text(response.body)
        title = extract_title(response.body)
        meta = extract_meta(response.body)

        {:ok, %{body: body, title: title, meta: meta}}

      {:error, reason} ->
        Logger.error("Failed to fetch #{url}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp extract_text(html) do
    html
    |> Floki.parse_document()
    |> Floki.text()
    |> String.trim()
    |> String.replace(~r/\s+/, " ")
    |> String.slice(0, 10_000)
  end

  defp extract_title(html) do
    case Floki.find(html, "title") do
      [] -> nil
      [{_, _, [title]}] -> title
      _ -> nil
    end
  end

  defp extract_meta(html) do
    description =
      case Floki.find(html, "meta[name=\"description\"]") do
        [] -> nil
        [{_, attrs, _}] -> Enum.find_value(attrs, fn {k, v} -> if k == "content", do: v end)
      end

    keywords =
      case Floki.find(html, "meta[name=\"keywords\"]") do
        [] ->
          []

        [{_, attrs, _}] ->
          case Enum.find_value(attrs, fn {k, v} -> if k == "content", do: v end) do
            nil -> []
            k -> String.split(k, ",", trim: true)
          end
      end

    %{description: description, keywords: keywords}
  end

  defp extract_links(html, base_url) do
    html
    |> Floki.find("a[href]")
    |> Floki.attribute("href")
    |> Enum.map(&resolve_url(&1, base_url))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp resolve_url(href, base_url) do
    uri = URI.merge(base_url, href)
    uri = %{uri | fragment: nil, query: nil}
    to_string(uri)
  rescue
    _ -> nil
  end

  defp is_external?(url, base_url) do
    parsed = URI.parse(url)
    base_parsed = URI.parse(base_url)

    parsed.host != base_parsed.host
  end

  defp store_in_r2(product_id, pages) do
    timestamp = DateTime.utc_now() |> DateTime.to_unix()

    keys = %{pages: [], screenshots: []}

    Enum.reduce(pages, {:ok, keys}, fn page, {:ok, acc} ->
      page_key = "snapshots/#{product_id}/site/#{timestamp}/#{slugify(page.url)}.json"

      page_json = JSON.encode!(page)

      case Storage.put_object(page_key, page_json, content_type: "application/json") do
        {:ok, url} ->
          pages = [%{key: page_key, url: url, title: page.title} | acc.pages]
          {:ok, %{acc | pages: pages}}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  defp slugify(url) do
    url
    |> String.replace(~r/[^a-zA-Z0-9]/, "-")
    |> String.replace(~r/-+/, "-")
    |> String.slice(0, 50)
  end

  defp create_snapshot(product_id, r2_keys, pages) do
    token_count = Enum.reduce(pages, 0, fn p, acc -> acc + div(String.length(p.content), 4) end)

    Products.create_product_snapshot(%{
      product_id: product_id,
      snapshot_type: "site",
      r2_keys: r2_keys,
      token_count: token_count,
      content_summary: "Site snapshot with #{length(pages)} pages, ~#{token_count} tokens"
    })
  end
end
