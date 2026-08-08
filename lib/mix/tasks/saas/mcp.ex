defmodule Mix.Tasks.Defdo.Saas.Mcp do
  @moduledoc """
  Runs the defdo SaaS MCP server over stdio.

      mix defdo.saas.mcp
      mix defdo.saas.mcp --root /path/to/some/defdo/saas/app

  Exposes three read-only tools over the catalog `Defdo.Tasks.Saas.Stack`,
  `Defdo.Tasks.Saas.MigratorChain` and `Defdo.Tasks.Saas.Audit` already
  compute: `defdo_saas.stack`, `defdo_saas.migrator_chain`,
  `defdo_saas.audit`. See issue #4 for why nothing here writes, generates,
  installs, or migrates -- those stay `mix defdo.saas.install` /
  `mix defdo.saas.migrations`, so the change a model proposes still lands in a
  diff a human reviews.

  `--root` sets the *default* project root a tool call falls back to when its
  own `arguments` omit `root` -- each call may still point at a different app
  by passing `root` explicitly, which matters for the estate use case this
  server exists for: one running server, asked about several of the ~15
  existing apps that will never be regenerated.

  ## stdout carries frames and nothing else

  Copied from `Defdo.Theme.Components.MCP`'s own task, whose moduledoc
  explains why this is two mechanisms and not one: `app.start` reinstalls the
  logger handler from config, and `:logger_std_h` refuses to change its `type`
  in place, so a one-line reconfigure silently does nothing. Both are needed
  here for the same reason -- a consuming app's boot logs landing on stdout
  breaks the JSON-RPC stream at the handshake, same as it did for that
  package's server.
  """

  use Mix.Task

  alias Defdo.Tasks.MCP.Stdio

  @shortdoc "Runs the defdo SaaS MCP stdio server"

  @impl Mix.Task
  def run(args) do
    {opts, argv, invalid} = OptionParser.parse(args, strict: [root: :string])

    refuse_unknown_arguments!(invalid, argv)

    # Before app.start, because app.start is what logs -- and again after,
    # because app.start reinstalls the handler.
    move_logging_off_stdout()

    Mix.Task.run("app.start")

    move_logging_off_stdout()

    Stdio.run(default_root: resolve_root!(Keyword.get(opts, :root)))
  end

  @doc """
  Points the default logger handler at stderr, so stdout carries JSON-RPC
  frames and nothing else. See the moduledoc for why this is two mechanisms.
  """
  def move_logging_off_stdout do
    Application.put_env(:logger, :default_handler, config: %{type: :standard_error})

    with {:ok, %{module: module, config: %{type: :standard_io} = config} = handler} <-
           :logger.get_handler_config(:default) do
      swap_handler(module, handler, config)
    else
      # No default handler, or one that already writes somewhere other than
      # stdout -- a file, an inbox, stderr already. Nothing to do.
      _other -> :ok
    end
  end

  defp swap_handler(module, handler, config) do
    replacement =
      handler |> Map.drop([:id, :module]) |> Map.put(:config, %{config | type: :standard_error})

    :ok = :logger.remove_handler(:default)

    case :logger.add_handler(:default, module, replacement) do
      :ok ->
        :ok

      {:error, reason} ->
        # The handler is gone at this point, so put the original back rather
        # than leaving the app with no logging at all.
        _ = :logger.add_handler(:default, module, Map.drop(handler, [:id, :module]))

        IO.puts(
          :stderr,
          "MCP could not move logging off stdout (#{inspect(reason)}); a log line on stdout " <>
            "will corrupt the JSON-RPC stream."
        )

        :ok
    end
  end

  defp refuse_unknown_arguments!([], []), do: :ok

  defp refuse_unknown_arguments!(invalid, argv) do
    unknown = Enum.map(invalid, fn {switch, _value} -> switch end) ++ argv

    Mix.raise(
      "unrecognised argument(s): #{Enum.join(unknown, " ")}. The only option is --root PATH. " <>
        "Accepting the typo silently would start the server with a different default root than " <>
        "the one asked for, with nothing said about it."
    )
  end

  defp resolve_root!(nil), do: "."

  defp resolve_root!(root) do
    expanded = Path.expand(root)

    if File.dir?(expanded) do
      expanded
    else
      Mix.raise(
        "refusing to start the MCP server: --root resolved to #{expanded}, which is not a " <>
          "directory. A tool call may still override root explicitly, but the default every " <>
          "call without one would fall back to does not exist."
      )
    end
  end
end
