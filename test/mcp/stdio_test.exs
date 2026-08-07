defmodule Defdo.Tasks.MCP.StdioTest do
  @moduledoc """
  Covers the transport's failure paths, mirroring
  `Defdo.Theme.Components.MCP.StdioTest`: a malformed frame, a handler that
  raises, and the server's own error replies must all keep the caller's read
  loop alive rather than dropping the session.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Defdo.Tasks.MCP.{Server, Stdio}

  defp state, do: Server.new()

  defp process_logged(line, state) do
    ref = make_ref()
    parent = self()

    logged = capture_io(:stderr, fn -> send(parent, {ref, Stdio.process_line(line, state)}) end)

    assert_received {^ref, result}
    {result, logged}
  end

  defp call(id, tool, arguments \\ %{}) do
    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{"name" => tool, "arguments" => arguments}
    })
  end

  test "an undecodable line answers -32700 instead of silence" do
    {{[frame], returned}, logged} = process_logged("{ not json", state())

    assert %{"jsonrpc" => "2.0", "id" => nil, "error" => error} = frame
    assert error["code"] == -32_700
    assert error["message"] == "Parse error"
    assert returned == state()
    assert logged =~ "MCP JSON decode failed"
  end

  test "a blank line is not an error and writes nothing" do
    assert {[], _state} = Stdio.process_line("", state())
  end

  test "valid JSON that is not a JSON-RPC message is ignored without a reply" do
    assert {[], _state} = Stdio.process_line(~s({"hello": "world"}), state())
  end

  test "a handler that raises answers -32603 and keeps the caller's loop alive" do
    # `deps` must be a list for `parse_deps/1` to match; a map is the shape
    # that reaches no clause and raises inside `call_tool/3`.
    line = call(1, "defdo_saas.audit", %{"root" => ".", "deps" => %{"not" => "a list"}})

    {{[frame], returned}, logged} = process_logged(line, state())

    assert %{"jsonrpc" => "2.0", "id" => 1, "error" => error} = frame
    assert error["code"] == -32_603
    assert error["message"] == "Internal error"
    assert error["data"]["exception"] == "FunctionClauseError"
    assert logged =~ "MCP handler crashed"
    assert returned == state()
  end

  test "an unknown tool answers -32602 through the transport" do
    assert {[%{"id" => 2, "error" => error}], _state} =
             Stdio.process_line(call(2, "defdo_saas.nope"), state())

    assert error["code"] == -32_602
    assert error["data"]["name"] == "defdo_saas.nope"
  end

  test "a notification carries no id, so it is acknowledged with no frame" do
    line = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"})

    assert {[], _state} = Stdio.process_line(line, state())
  end
end
