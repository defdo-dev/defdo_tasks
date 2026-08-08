defmodule Mix.Tasks.Defdo.Saas.McpConfigTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Mix.Tasks.Defdo.Saas.McpConfig

  describe "config/1" do
    test "points the mcpServers block at `mix defdo.saas.mcp --root <root>`" do
      assert McpConfig.config("/apps/my_app") == %{
               "mcpServers" => %{
                 "defdo_saas" => %{
                   "command" => "mix",
                   "args" => ["defdo.saas.mcp", "--root", "/apps/my_app"]
                 }
               }
             }
    end
  end

  describe "run/1" do
    test "prints valid, pretty-printed JSON defaulting root to the current directory" do
      output = capture_io(fn -> McpConfig.run([]) end)

      assert {:ok, decoded} = Jason.decode(output)
      assert decoded == McpConfig.config(File.cwd!())
      # pretty-printed, not a single line
      assert output =~ "\n"
    end

    test "--root overrides the default and is expanded to an absolute path" do
      output = capture_io(fn -> McpConfig.run(["--root", "relative/path"]) end)

      {:ok, decoded} = Jason.decode(output)
      root = get_in(decoded, ["mcpServers", "defdo_saas", "args"]) |> List.last()

      assert root == Path.expand("relative/path")
      assert Path.type(root) == :absolute
    end

    test "an unrecognised argument raises rather than being silently ignored" do
      assert_raise Mix.Error, ~r/unrecognised argument/, fn ->
        capture_io(fn -> McpConfig.run(["--bogus", "x"]) end)
      end
    end

    test "a stray positional argument raises the same way" do
      assert_raise Mix.Error, ~r/unrecognised argument/, fn ->
        capture_io(fn -> McpConfig.run(["extra"]) end)
      end
    end
  end
end
