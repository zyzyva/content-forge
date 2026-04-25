defmodule ContentForgeMCP.StdioServer do
  @moduledoc """
  Stdio transport for the Content Forge MCP server.

  Mirrors the lead_intelligence pattern: a Claude Code session
  spawns this module via `mix content_forge_mcp` (or a
  `start_iex.sh`-style wrapper); the BEAM runs the loop in
  foreground, reading JSON-RPC requests on stdin and writing
  JSON-RPC responses on stdout.

  Differences from lead_intelligence's stdio transport:

    * The Phoenix endpoint is disabled at start so a launchd-managed
      Phoenix on the same box does not collide.
    * Tool errors render as JSON objects in the text content slot
      (no "Error: " prefix); a Claude session can parse the
      content text directly into the documented
      `%{code, message, details}` envelope.
  """

  alias ContentForgeMCP.Server

  @server_info %{
    "name" => "Content Forge",
    "version" => "1.0.0"
  }

  @capabilities %{
    "tools" => %{}
  }

  def start do
    # Disable the HTTP endpoint so stdio MCP does not conflict with
    # the launchd-managed Phoenix server on the same box.
    endpoint_config = Application.get_env(:content_forge, ContentForgeWeb.Endpoint, [])

    Application.put_env(
      :content_forge,
      ContentForgeWeb.Endpoint,
      Keyword.put(endpoint_config, :server, false)
    )

    IO.puts(:stderr, "Content Forge MCP stdio server starting...")
    {:ok, _} = Application.ensure_all_started(:content_forge)
    loop()
  end

  defp loop do
    case IO.read(:stdio, :line) do
      :eof -> :ok
      {:error, _reason} -> :ok
      line -> line |> String.trim() |> handle_line() && loop()
    end
  end

  defp handle_line(""), do: true

  defp handle_line(line) do
    case JSON.decode(line) do
      {:ok, request} ->
        request |> handle_request() |> send_response()

      {:error, _} ->
        send_error(nil, -32_700, "Parse error")
    end

    true
  end

  defp handle_request(%{"jsonrpc" => "2.0", "method" => method, "id" => id} = request) do
    params = Map.get(request, "params", %{})

    case dispatch(method, params) do
      {:ok, result} ->
        %{"jsonrpc" => "2.0", "id" => id, "result" => result}

      {:error, code, message} ->
        %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}
    end
  end

  defp handle_request(%{"jsonrpc" => "2.0", "method" => method} = request) do
    # Notification (no id): dispatch but do not respond.
    params = Map.get(request, "params", %{})
    dispatch(method, params)
    nil
  end

  defp handle_request(_) do
    %{
      "jsonrpc" => "2.0",
      "id" => nil,
      "error" => %{"code" => -32_600, "message" => "Invalid Request"}
    }
  end

  defp dispatch("initialize", _params) do
    {:ok,
     %{
       "protocolVersion" => "2024-11-05",
       "capabilities" => @capabilities,
       "serverInfo" => @server_info
     }}
  end

  defp dispatch("notifications/initialized", _params), do: {:ok, nil}

  defp dispatch("tools/list", _params) do
    tools = Enum.map(Server.tools(), &SimpleMCP.Tool.to_mcp_format/1)
    {:ok, %{"tools" => tools}}
  end

  defp dispatch("tools/call", %{"name" => name, "arguments" => args}) do
    case Server.handle_tool_call(name, args || %{}) do
      {:ok, result} ->
        {:ok,
         %{
           "content" => [%{"type" => "text", "text" => format_result(result)}]
         }}

      {:error, %{} = envelope} ->
        # Structured error envelope: render as JSON in the text slot
        # so a Claude session parses the content directly into the
        # documented %{code, message, details} shape.
        {:ok,
         %{
           "content" => [%{"type" => "text", "text" => JSON.encode!(envelope)}],
           "isError" => true
         }}

      {:error, message} when is_binary(message) ->
        {:ok,
         %{
           "content" => [%{"type" => "text", "text" => message}],
           "isError" => true
         }}
    end
  end

  defp dispatch("tools/call", %{"name" => name}) do
    dispatch("tools/call", %{"name" => name, "arguments" => %{}})
  end

  defp dispatch(method, _params) do
    {:error, -32_601, "Method not found: #{method}"}
  end

  defp format_result(result) when is_binary(result), do: result
  defp format_result(result), do: JSON.encode!(result)

  defp send_response(nil), do: :ok

  defp send_response(response) do
    IO.puts(JSON.encode!(response))
  end

  defp send_error(id, code, message) do
    send_response(%{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => code, "message" => message}
    })
  end
end
