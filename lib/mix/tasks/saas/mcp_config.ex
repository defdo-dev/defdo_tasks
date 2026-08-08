defmodule Mix.Tasks.Defdo.Saas.McpConfig do
  @moduledoc """
  Prints the MCP client config block for the defdo SaaS server.

      mix defdo.saas.mcp_config
      mix defdo.saas.mcp_config --root /path/to/app

  Paste the printed `"defdo_saas"` entry into an MCP client's server list
  (Claude Code's `.mcp.json`, Claude Desktop's `claude_desktop_config.json`,
  or equivalent) to register `mix defdo.saas.mcp` (see that task) as a stdio
  server offering `defdo_saas.stack`, `defdo_saas.migrator_chain` and
  `defdo_saas.audit`.

  ## Divergence from the precedent

  The file layout here mirrors
  `defdo.theme.components.aceternity.mcp_config` -- strict `OptionParser`,
  refused unknown arguments -- but that task's actual job is to write a
  scratch `components.json` file, guarded by a scratch-path refusal and a
  `git check-ignore` verification. This task never writes anything; it only
  prints a JSON block to stdout for the operator to paste into their own
  client config, so neither guard applies and nothing here creates a file to
  guard.

  `--root PATH` pins the server's *default* project root (see
  `mix defdo.saas.mcp`) to an absolute path, so the emitted config works
  regardless of the working directory the MCP client launches the server
  from. Defaults to the current directory, expanded to an absolute path --
  run this from inside the defdo SaaS app you want the server answering
  about by default. Each tool call may still override `root` explicitly.
  """

  use Mix.Task

  @shortdoc "Prints the MCP client config block for the defdo SaaS server"

  @impl Mix.Task
  def run(args) do
    {opts, argv, invalid} = OptionParser.parse(args, strict: [root: :string])

    refuse_unknown_arguments!(invalid, argv)

    root = opts |> Keyword.get(:root, File.cwd!()) |> Path.expand()

    Mix.shell().info(Jason.encode!(config(root), pretty: true))
  end

  @doc "The `mcpServers` block this task prints, as data."
  @spec config(String.t()) :: map()
  def config(root) do
    %{
      "mcpServers" => %{
        "defdo_saas" => %{
          "command" => "mix",
          "args" => ["defdo.saas.mcp", "--root", root]
        }
      }
    }
  end

  defp refuse_unknown_arguments!([], []), do: :ok

  defp refuse_unknown_arguments!(invalid, argv) do
    unknown = Enum.map(invalid, fn {switch, _value} -> switch end) ++ argv

    Mix.raise(
      "unrecognised argument(s): #{Enum.join(unknown, " ")}. The only option is --root PATH."
    )
  end
end
