defmodule ContentForge.Jobs.RepoIngestion do
  @moduledoc """
  Oban job that clones a repository, extracts text content (README, docs, source files),
  and stores it as a product snapshot in R2.
  """
  use Oban.Worker, queue: :ingestion, max_attempts: 3

  require Logger

  alias ContentForge.Products
  alias ContentForge.Storage

  @max_token_count Application.compile_env(:content_forge, :max_ingestion_tokens, 50_000)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"product_id" => product_id, "repo_url" => repo_url}}) do
    Logger.info("Starting repo ingestion for product #{product_id} from #{repo_url}")

    with {:ok, _product} <- fetch_product(product_id),
         {:ok, temp_dir} <- clone_repo(repo_url),
         {:ok, extracted_content} <- extract_content(temp_dir),
         :ok <- cleanup_temp_dir(temp_dir),
         {:ok, r2_keys} <- store_in_r2(product_id, extracted_content),
         {:ok, _snapshot} <- create_snapshot(product_id, r2_keys, extracted_content.token_count) do
      Logger.info("Repo ingestion completed for product #{product_id}")
      :ok
    else
      {:error, reason} ->
        Logger.error("Repo ingestion failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp fetch_product(product_id) do
    case Products.get_product(product_id) do
      nil -> {:error, :not_found}
      product -> {:ok, product}
    end
  end

  defp clone_repo(repo_url) do
    temp_dir = Path.join(System.tmp_dir(), "content_forge_repo_#{:erlang.unique_integer()}")

    case File.mkdir_p(temp_dir) do
      :ok ->
        Logger.info("Cloning #{repo_url} to #{temp_dir}")

        case System.cmd("git", ["clone", "--depth", "1", repo_url, temp_dir],
               stderr_to_stdout: true
             ) do
          {_, 0} ->
            {:ok, temp_dir}

          {output, _} ->
            Logger.error("Git clone failed: #{output}")
            cleanup_temp_dir(temp_dir)
            {:error, {:git_clone_failed, output}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_content(temp_dir) do
    Logger.info("Extracting content from #{temp_dir}")

    content_parts =
      [
        read_file(Path.join(temp_dir, "README.md")),
        read_file(Path.join(temp_dir, "README")),
        read_file(Path.join(temp_dir, "CHANGELOG.md")),
        read_file(Path.join(temp_dir, "CHANGELOG")),
        read_file(Path.join(temp_dir, "LICENSE"))
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&add_metadata(&1, "root"))

    doc_files = files_in_dir(Path.join(temp_dir, "docs"))
    lib_files = files_in_dir(Path.join(temp_dir, "lib"))
    src_files = files_in_dir(Path.join(temp_dir, "src"))

    doc_content = Enum.map(doc_files, &read_and_tag/1)
    lib_content = Enum.map(lib_files, &read_and_tag/1)
    src_content = Enum.map(src_files, &read_and_tag/1)

    all_content = content_parts ++ doc_content ++ lib_content ++ src_content

    text = Enum.join(all_content, "\n\n")
    token_count = estimate_tokens(text)

    Logger.info("Extracted #{token_count} tokens from repository")

    if token_count > @max_token_count do
      truncated = truncate_to_tokens(text, @max_token_count)
      {:ok, %{content: truncated, token_count: @max_token_count}}
    else
      {:ok, %{content: text, token_count: token_count}}
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, content} -> content
      _ -> nil
    end
  end

  defp read_and_tag(path) do
    content = read_file(path)
    if content, do: add_metadata(content, Path.extname(path)), else: nil
  end

  defp add_metadata(content, source) do
    "=== #{source} ===\n#{content}"
  end

  defp files_in_dir(dir) do
    case File.dir?(dir) do
      true ->
        Path.wildcard(Path.join(dir, "**/*"))
        |> Enum.filter(&File.regular?/1)
        |> Enum.reject(fn f ->
          ext = Path.extname(f)
          ext in [".exe", ".so", ".dll", ".dylib", ".lock"]
        end)
        |> Enum.take(20)

      false ->
        []
    end
  end

  defp estimate_tokens(text) do
    div(String.length(text), 4)
  end

  defp truncate_to_tokens(text, max_tokens) do
    max_chars = max_tokens * 4

    if String.length(text) > max_chars do
      String.slice(text, 0, max_chars) <> "\n\n[... content truncated ...]"
    else
      text
    end
  end

  defp cleanup_temp_dir(dir) do
    case File.rm_rf(dir) do
      {:ok, _} ->
        Logger.info("Cleaned up temp directory #{dir}")
        :ok

      {:error, reason, _} ->
        Logger.warning("Failed to cleanup temp directory #{dir}: #{inspect(reason)}")
        :ok
    end
  end

  defp store_in_r2(product_id, %{content: content, token_count: token_count}) do
    key = "snapshots/#{product_id}/repo/#{DateTime.utc_now() |> DateTime.to_unix()}.txt"

    case Storage.put_object(key, content, content_type: "text/plain") do
      {:ok, url} ->
        {:ok, %{content_key: key, content_url: url, token_count: token_count}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_snapshot(product_id, r2_keys, token_count) do
    Products.create_product_snapshot(%{
      product_id: product_id,
      snapshot_type: "repo",
      r2_keys: r2_keys,
      token_count: token_count,
      content_summary: "Repository snapshot with #{token_count} tokens"
    })
  end
end
