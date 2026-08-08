defmodule Mix.Tasks.Defdo.Saas.McpTest do
  @moduledoc """
  Only the stdout-hygiene mechanism is covered here, mirroring the scope of
  the precedent's own test (`Mix.Tasks.McpStdoutTest` in
  defdo_theme_components): `run/1` itself needs `app.start` and a live stdio
  loop, which is what `mix defdo.saas.mcp` is for, not what an ExUnit test
  should drive.

  `async: false` on purpose: these assertions move the VM's default logger
  handler.
  """
  use ExUnit.Case, async: false

  alias Mix.Tasks.Defdo.Saas.Mcp

  setup do
    {:ok, original} = :logger.get_handler_config(:default)
    original_env = Application.get_env(:logger, :default_handler)

    install(original, :standard_io)

    on_exit(fn ->
      install(original, get_in(original, [:config, :type]))

      case original_env do
        nil -> Application.delete_env(:logger, :default_handler)
        env -> Application.put_env(:logger, :default_handler, env)
      end
    end)

    :ok
  end

  defp install(handler, type) do
    :logger.remove_handler(:default)

    config =
      handler
      |> Map.drop([:id, :module])
      |> Map.put(:config, %{handler.config | type: type})

    :ok = :logger.add_handler(:default, handler.module, config)
  end

  defp handler_type do
    {:ok, config} = :logger.get_handler_config(:default)
    get_in(config, [:config, :type])
  end

  test "the live handler moves off stdout" do
    assert handler_type() == :standard_io

    assert Mcp.move_logging_off_stdout() == :ok
    assert handler_type() == :standard_error
  end

  test "a handler already off stdout is left alone" do
    Mcp.move_logging_off_stdout()
    {:ok, moved} = :logger.get_handler_config(:default)

    assert Mcp.move_logging_off_stdout() == :ok

    {:ok, again} = :logger.get_handler_config(:default)
    assert get_in(again, [:config, :type]) == :standard_error
    assert again.module == moved.module
  end
end
