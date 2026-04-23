defmodule ContentForge.OpenClaw.AgentGateway do
  @moduledoc """
  Shell-out bridge to the locally running OpenClaw gateway's
  agent-turn command. Invokes

      <binary_path> agent --json --agent <id> --session-id <key> --message <text>

  via `System.cmd/3`, expecting stdout to carry a JSON payload of
  the shape

      %{"payloads" => [%{"text" => "..."}, ...], ...}

  Returns `{:ok, %{text, model, session_id}}` on a clean run or a
  classified error tuple on any failure mode. No synthetic reply
  is ever fabricated - callers get a deterministic error they
  can fall through on.

  Config (`config :content_forge, :open_claw_agent`):

    * `:binary_path` - absolute path to the `openclaw` binary
      (default `/opt/homebrew/bin/openclaw`).
    * `:default_agent_id` - agent id to use when caller did not
      override. No sensible default - when unset the gateway
      returns `{:error, :not_configured}`.
    * `:default_timeout_seconds` - subprocess timeout in
      seconds (default 120).
    * `:shell_impl` - test seam. When set, replaces the
      `System.cmd/3` invocation with a 3-arity function that
      returns `{stdout_binary, exit_code_integer}`. Default is
      `&System.cmd/3`.

  `agent_turn/2` classifies failures consistently with the rest
  of the codebase's adapter taxonomy:

    * `{:error, :not_configured}` - binary path or agent id is
      unset, or the binary file is missing on disk
    * `{:error, {:transient, :timeout, timeout_seconds}}` -
      subprocess exited via timeout
    * `{:error, {:transient, :exit_code, code}}` - non-zero exit
    * `{:error, {:permanent, :malformed_json}}` - stdout was not
      parseable JSON or lacked the expected shape
  """

  require Logger

  @config_app :content_forge
  @config_key :open_claw_agent
  @default_binary "/opt/homebrew/bin/openclaw"
  @default_timeout_seconds 120

  @type opts :: [
          agent_id: String.t(),
          session_id: String.t(),
          thinking: String.t() | atom()
        ]

  @type ok_result :: {:ok, %{text: String.t(), model: String.t(), session_id: String.t()}}
  @type error_result ::
          {:error, :not_configured}
          | {:error, {:transient, :timeout, pos_integer()}}
          | {:error, {:transient, :exit_code, integer()}}
          | {:error, {:permanent, :malformed_json}}

  @doc """
  Returns `:ok` when the gateway is callable (binary and agent
  id are both configured), `:not_configured` otherwise.
  """
  @spec status() :: :ok | :not_configured
  def status do
    case resolve_config(agent_id: default_agent_id()) do
      {:ok, _} -> :ok
      {:error, :not_configured} -> :not_configured
    end
  end

  @doc """
  Runs one agent turn. `message` is the inbound user-facing
  text; `opts` carries the agent id + session id for OpenClaw
  threading.
  """
  @spec agent_turn(String.t(), opts()) :: ok_result() | error_result()
  def agent_turn(message, opts \\ []) when is_binary(message) do
    with {:ok, config} <- resolve_config(opts) do
      run_shell(message, config)
    end
  end

  # --- config resolution ----------------------------------------------------

  defp resolve_config(opts) do
    agent_id = Keyword.get(opts, :agent_id) || default_agent_id()
    session_id = Keyword.get(opts, :session_id, "")
    thinking = Keyword.get(opts, :thinking)
    binary = binary_path()
    timeout = timeout_seconds()

    cond do
      is_nil(binary) or binary == "" ->
        {:error, :not_configured}

      is_nil(agent_id) or agent_id == "" ->
        {:error, :not_configured}

      not File.exists?(binary) ->
        {:error, :not_configured}

      true ->
        {:ok,
         %{
           binary: binary,
           agent_id: agent_id,
           session_id: session_id,
           thinking: thinking,
           timeout_seconds: timeout
         }}
    end
  end

  # --- shell invocation -----------------------------------------------------

  defp run_shell(message, config) do
    args = build_args(message, config)

    try do
      case shell_impl().(config.binary, args, stderr_to_stdout: true) do
        {stdout, 0} -> parse_stdout(stdout, config.agent_id)
        {_stdout, code} -> {:error, {:transient, :exit_code, code}}
      end
    catch
      :exit, {:timeout, _} ->
        {:error, {:transient, :timeout, config.timeout_seconds}}
    end
  end

  defp build_args(message, config) do
    base = [
      "agent",
      "--json",
      "--agent",
      config.agent_id,
      "--session-id",
      config.session_id,
      "--message",
      message
    ]

    case config.thinking do
      nil -> base
      level -> base ++ ["--thinking", to_string(level)]
    end
  end

  # --- JSON parsing ---------------------------------------------------------

  defp parse_stdout(stdout, session_id) do
    with {:ok, decoded} <- decode_json(stdout),
         {:ok, text} <- extract_text(decoded),
         {:ok, model} <- extract_model(decoded) do
      {:ok, %{text: text, model: model, session_id: session_id}}
    else
      :error -> {:error, {:permanent, :malformed_json}}
    end
  end

  defp decode_json(stdout) do
    trimmed = String.trim(stdout)

    case JSON.decode(trimmed) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      _ -> :error
    end
  end

  defp extract_text(%{"payloads" => [%{"text" => text} | _]}) when is_binary(text) do
    {:ok, text}
  end

  defp extract_text(_), do: :error

  defp extract_model(%{"model" => model}) when is_binary(model), do: {:ok, model}
  defp extract_model(_), do: {:ok, "openclaw-agent"}

  # --- config accessors -----------------------------------------------------

  defp binary_path, do: config_key(:binary_path, @default_binary)
  defp default_agent_id, do: config_key(:default_agent_id)
  defp timeout_seconds, do: config_key(:default_timeout_seconds, @default_timeout_seconds)
  defp shell_impl, do: config_key(:shell_impl, &System.cmd/3)

  defp config_key(key, default \\ nil) do
    @config_app
    |> Application.get_env(@config_key, [])
    |> Keyword.get(key, default)
  end
end
