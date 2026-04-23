defmodule ContentForge.Jobs.SiteCrawlerTest do
  use ContentForge.DataCase, async: false

  use Oban.Testing, repo: ContentForge.Repo

  import ExUnit.CaptureLog

  alias ContentForge.Jobs.SiteCrawler

  describe "perform/1 entry guards" do
    test "returns {:error, :not_found} when product does not exist" do
      log =
        capture_log(fn ->
          assert {:error, :not_found} =
                   perform_job(SiteCrawler, %{
                     "product_id" => Ecto.UUID.generate(),
                     "site_url" => "https://example.com"
                   })
        end)

      assert log =~ "Site crawl failed"
    end
  end

  describe "extract_links/2 logic (via Floki)" do
    test "resolves relative href to absolute URL using base URI" do
      html = ~s(<html><body><a href="/page2">Link</a></body></html>)
      base_url = URI.parse("https://example.com")

      {:ok, doc} = Floki.parse_document(html)

      links =
        doc
        |> Floki.find("a[href]")
        |> Floki.attribute("href")
        |> Enum.map(fn href ->
          uri = URI.merge(base_url, href)
          uri = %{uri | fragment: nil, query: nil}
          to_string(uri)
        end)

      assert links == ["https://example.com/page2"]
    end

    test "ignores links where host differs from base" do
      html = ~s(<html><body>
        <a href="/internal">Internal</a>
        <a href="https://other.com/page">External</a>
      </body></html>)

      base_url = URI.parse("https://example.com")

      {:ok, doc} = Floki.parse_document(html)

      links =
        doc
        |> Floki.find("a[href]")
        |> Floki.attribute("href")
        |> Enum.map(fn href ->
          uri = URI.merge(base_url, href)
          uri = %{uri | fragment: nil, query: nil}
          to_string(uri)
        end)
        |> Enum.reject(fn url ->
          parsed = URI.parse(url)
          parsed.host != base_url.host
        end)

      assert links == ["https://example.com/internal"]
    end
  end

  describe "extract_meta/1 logic (via Floki)" do
    test "extracts description from meta tag" do
      html = ~s(<html><head><meta name="description" content="Hello"></head><body></body></html>)

      {:ok, doc} = Floki.parse_document(html)

      description =
        case Floki.find(doc, ~s(meta[name="description"])) do
          [] ->
            nil

          [{_, attrs, _}] ->
            Enum.find_value(attrs, fn {k, v} -> if k == "content", do: v end)
        end

      assert description == "Hello"
    end

    test "returns nil description when no meta description tag" do
      html = ~s(<html><head><title>No Meta</title></head><body></body></html>)

      {:ok, doc} = Floki.parse_document(html)

      description =
        case Floki.find(doc, ~s(meta[name="description"])) do
          [] ->
            nil

          [{_, attrs, _}] ->
            Enum.find_value(attrs, fn {k, v} -> if k == "content", do: v end)
        end

      assert description == nil
    end

    test "attributes are string-keyed tuples, not keyword list" do
      html = ~s(<html><head><meta name="description" content="Test value"></head></html>)

      {:ok, doc} = Floki.parse_document(html)
      [{_, attrs, _}] = Floki.find(doc, ~s(meta[name="description"]))

      # Verify Floki returns string-keyed tuples
      assert {"content", "Test value"} in attrs

      # Verify old Keyword.get approach does NOT work (atoms vs strings)
      refute Keyword.get(attrs, :content) == "Test value"

      # Verify correct approach works
      value = Enum.find_value(attrs, fn {k, v} -> if k == "content", do: v end)
      assert value == "Test value"
    end
  end

  describe "resolve_url logic" do
    test "URI.merge returns struct directly, not {:ok, struct} tuple" do
      base = URI.parse("https://example.com/")
      result = URI.merge(base, "/about")

      # Confirm it returns a URI struct, not a tagged tuple
      assert %URI{} = result
      refute match?({:ok, _}, result)
      assert to_string(result) == "https://example.com/about"
    end

    test "resolved URL with fragment and query stripped" do
      base = URI.parse("https://example.com/")
      uri = URI.merge(base, "/page?q=1#section")
      stripped = %{uri | fragment: nil, query: nil}
      assert to_string(stripped) == "https://example.com/page"
    end
  end

  describe "Floki attribute access" do
    test "Floki requires parse_document before find" do
      html = ~s(<html><head><meta name="keywords" content="elixir, phoenix"></head></html>)
      {:ok, doc} = Floki.parse_document(html)
      result = Floki.find(doc, ~s(meta[name="keywords"]))
      assert length(result) == 1
    end

    test "Floki attributes are string-keyed tuples, not keyword lists" do
      html = ~s(<html><head><meta name="keywords" content="elixir, phoenix, oban"></head></html>)
      {:ok, doc} = Floki.parse_document(html)
      [{_, attrs, _}] = Floki.find(doc, ~s(meta[name="keywords"]))

      assert is_list(attrs)
      # Each element is a {string, string} tuple
      Enum.each(attrs, fn {k, _v} -> assert is_binary(k) end)
    end

    test "keywords are split correctly from meta content" do
      html = ~s(<html><head><meta name="keywords" content="elixir, phoenix, oban"></head></html>)
      {:ok, doc} = Floki.parse_document(html)

      keywords =
        case Floki.find(doc, ~s(meta[name="keywords"])) do
          [] ->
            []

          [{_, attrs, _}] ->
            case Enum.find_value(attrs, fn {k, v} -> if k == "content", do: v end) do
              nil -> []
              k -> String.split(k, ",", trim: true)
            end
        end

      assert length(keywords) == 3
      assert Enum.map(keywords, &String.trim/1) == ["elixir", "phoenix", "oban"]
    end
  end
end
