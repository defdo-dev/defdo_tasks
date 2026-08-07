defmodule Defdo.Tasks.MCP.Stdio do
  @moduledoc """
  Line-delimited JSON-RPC stdio transport for the defdo SaaS MCP server.

  Copied in shape from `Defdo.Theme.Components.MCP.Stdio`, whose moduledoc
  states the reason precisely enough to repeat rather than paraphrase: this is
  the last line of defence for an agent's session, and an exception escaping
  `Server.handle_message/2` would otherwise end the loop and drop the session
  with nothing on the wire. `dispatch/2` rescues, `process_line/2` never
  raises, and a JSON-RPC error object always answers a request that carried an
  id.
  """

  alias Defdo.Tasks.MCP.Server

  @parse_error -32_700
  @internal_error -32_603

  def run(opts \\ []) do
    opts
    |> Server.new()
    |> loop()
  end

  defp loop(state) do
    case IO.read(:stdio, :line) do
      :eof ->
        :ok

      {:error, reason} ->
        log("stdin read failed: #{inspect(reason)}")
        :ok

      line ->
        {frames, state} = line |> String.trim() |> process_line(state)
        Enum.each(frames, &emit/1)
        loop(state)
    end
  end

  @doc """
  Runs one transport step and returns `{frames_to_write, next_state}`.

  Never raises: a line this function cannot serve becomes an error frame, so
  the caller's loop is free to keep reading.
  """
  def process_line("", state), do: {[], state}

  def process_line(line, state) do
    case Jason.decode(line) do
      {:ok, message} ->
        dispatch(message, state)

      {:error, exception} ->
        detail = Exception.message(exception)
        log("JSON decode failed: #{detail}")

        # The id lives inside the frame that failed to parse, so it is
        # unknowable here; JSON-RPC 2.0 specifies null for exactly this case.
        {[error_frame(nil, @parse_error, "Parse error", %{"detail" => detail})], state}
    end
  end

  defp dispatch(message, state) do
    case Server.handle_message(message, state) do
      {:noreply, new_state} -> {[], new_state}
      {response, new_state} -> {[response], new_state}
    end
  rescue
    exception ->
      log("handler crashed: #{Exception.format(:error, exception, __STACKTRACE__)}")

      # State is deliberately the one from before the call: the handler raised
      # partway, so nothing it may have computed is trustworthy.
      case Map.get(message, "id") do
        # A notification carries no id and JSON-RPC forbids replying to one,
        # so the operator's stderr is the only channel left.
        nil ->
          {[], state}

        id ->
          data = %{
            "exception" => inspect(exception.__struct__),
            "detail" => Exception.message(exception)
          }

          {[error_frame(id, @internal_error, "Internal error", data)], state}
      end
  end

  defp emit(frame) do
    IO.puts(Jason.encode!(frame))
  rescue
    exception ->
      # A frame that cannot be encoded would otherwise raise here, outside
      # dispatch/2's rescue, and kill the loop after the handler already
      # succeeded.
      log("response encode failed: #{Exception.message(exception)}")

      IO.puts(
        Jason.encode!(
          error_frame(Map.get(frame, "id"), @internal_error, "Response could not be encoded", nil)
        )
      )
  end

  defp error_frame(id, code, message, data) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => code, "message" => message, "data" => data}
    }
  end

  defp log(message), do: IO.puts(:stderr, "MCP #{message}")
end
