defmodule ContentForge.OpenClaw.AgentGateway do
  @moduledoc """
  Shell-out bridge to the locally running OpenClaw gateway's
  agent-turn command. Invokes

      <binary_path> agent --json --agent <id> --session-id <key> --message <text>

  via a `Task.async`-wrapped `System.shell/2` call that
  redirects stderr to a tempfile so the two streams stay
  separate. Stdout carries the JSON payload of the shape

      %{"payloads" => [%{"text" => "..."}, ...], ...}

  Returns `{:ok, %{text, model, session_id}}` on a clean run or a
  classified error tuple on any failure mode. No synthetic reply
  is ever fabricated - callers get a deterministic error they
  can fall through on.

  ## Timeout + child-kill (14.2c-H)

  The subprocess runs inside a `Task.async`. After
  `timeout_seconds`, `Task.shutdown(task, :brutal_kill)` tears
  down the task process, which in turn closes the underlying
  Port and sends SIGTERM to the OS subprocess. Timeout returns
  `{:error, {:transient, :timeout, seconds}}`.

  ## stderr handling (14.2c-H)

  stderr is captured in a tempfile via a shell `2>` redirect,
  read back, logged at `:debug` level, and - on non-zero exit
  only - surfaced in the error reason for operator diagnosis:

      {:error, {:transient, :exit_code, %{code: 1, stderr: "..."}}}

  Config (`config :content_forge, :open_claw_agent`):

    * `:binary_path` - absolute path to the `openclaw` binary
      (default `/opt/homebrew/bin/openclaw`).
    * `:default_agent_id` - agent id to use when caller did not
      override. No sensible default - when unset the gateway
      returns `{:error, :not_configured}`.
    * `:default_timeout_seconds` - subprocess timeout in
      seconds (default 120). Enforced by the Task.async wrapper.
    * `:shell_impl` - test seam. When set, replaces the real
      shell-out with a 2-arity function `(binary, args)` that
      returns `{stdout_binary, stderr_binary, exit_code}`.
      Default uses `System.shell/2` with tempfile-stderr.

  `agent_turn/2` classifies failures consistently with the rest
  of the codebase's adapter taxonomy:

    * `{:error, :not_configured}` - binary path or agent id is
      unset, or the binary file is missing on disk
    * `{:error, {:transient, :timeout, timeout_seconds}}` -
      subprocess killed after timeout
    * `{:error, {:transient, :exit_code, %{code: n, stderr: s}}}`
      - non-zero exit; stderr included for operator diagnosis
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
          | {:error, {:transient, :exit_code, %{code: integer(), stderr: String.t()}}}
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
    timeout_ms = config.timeout_seconds * 1000

    task = Task.async(fn -> shell_impl().(config.binary, args) end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {stdout, stderr, 0}} ->
        log_stderr(stderr)
        parse_stdout(stdout, config.agent_id)

      {:ok, {_stdout, stderr, code}} ->
        log_stderr(stderr)

        {:error, {:transient, :exit_code, %{code: code, stderr: String.trim(stderr || "")}}}

      nil ->
        Logger.warning(
          "OpenClaw.AgentGateway: subprocess killed after timeout (#{config.timeout_seconds}s)"
        )

        {:error, {:transient, :timeout, config.timeout_seconds}}

      # Task shutdown returned a different shape (e.g., exit
      # reason). Treat as a transient failure so Oban retries.
      {:exit, reason} ->
        Logger.warning("OpenClaw.AgentGateway: task exited unexpectedly: #{inspect(reason)}")

        {:error, {:transient, :exit_code, %{code: -1, stderr: inspect(reason)}}}
    end
  end

  defp log_stderr(""), do: :ok
  defp log_stderr(nil), do: :ok

  defp log_stderr(stderr) when is_binary(stderr) do
    Logger.debug(["OpenClaw.AgentGateway stderr: ", stderr])
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
  defp shell_impl, do: config_key(:shell_impl, &__MODULE__.default_shell/2)

  @doc false
  # Default shell-out: runs `binary args 2>tempfile`, reads the
  # tempfile back as stderr, deletes it, returns the 3-tuple.
  # Exposed as a public function (under @doc false) so the
  # default function reference `&__MODULE__.default_shell/2`
  # stays cheap to look up.
  def default_shell(binary, args) do
    stderr_path =
      Path.join(
        System.tmp_dir!(),
        "openclaw_stderr_#{:erlang.unique_integer([:positive])}.log"
      )

    escaped_args = Enum.map_join(args, " ", &shell_escape/1)

    shell_cmd =
      shell_escape(binary) <> " " <> escaped_args <> " 2>" <> shell_escape(stderr_path)

    try do
      {stdout, exit_code} = System.shell(shell_cmd)
      stderr = File.read!(stderr_path)
      {stdout, stderr, exit_code}
    after
      _ = File.rm(stderr_path)
    end
  end

  defp shell_escape(arg) when is_binary(arg) do
    "'" <> String.replace(arg, "'", "'\\''") <> "'"
  end

  defp config_key(key, default \\ nil) do
    @config_app
    |> Application.get_env(@config_key, [])
    |> Keyword.get(key, default)
  end
end
