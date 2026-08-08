defmodule Defdo.Tasks.RepoCompiledConfigTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias Defdo.Tasks.Saas.Audit
  alias Mix.Tasks.Defdo.Repo.CompiledConfig

  setup do
    on_exit(fn ->
      File.rm("config/compiled_test.exs")
      File.rm("config/defdo_compiled_config.exs")
    end)

    :ok
  end

  describe "generating" do
    test "writes the flavour file and prints the import hint" do
      assert ExUnit.CaptureIO.capture_io(fn ->
               assert CompiledConfig.run(["--filename", "compiled_test"])
             end) =~ "import_config \"compiled_test.exs\""

      assert File.exists?("config/compiled_test.exs")
      assert File.read!("config/compiled_test.exs") =~ "defmodule Defdo.Repo.CompileConfig do"
    end

    test "defaults the filename" do
      assert ExUnit.CaptureIO.capture_io(fn -> CompiledConfig.run([]) end) =~
               "import_config \"defdo_compiled_config.exs\""

      assert File.exists?("config/defdo_compiled_config.exs")
    end

    test "what it generates is valid Elixir" do
      ExUnit.CaptureIO.capture_io(fn -> CompiledConfig.run([]) end)

      assert {:ok, _ast} =
               "config/defdo_compiled_config.exs" |> File.read!() |> Code.string_to_quoted()
    end

    test "keys are binary_id and timestamps are timestamptz" do
      ExUnit.CaptureIO.capture_io(fn -> CompiledConfig.run([]) end)
      source = File.read!("config/defdo_compiled_config.exs")

      assert source =~
               "def migration_primary_key(extras \\\\ []) when is_list(extras),\n      do: [type: :binary_id]"

      assert source =~
               "def migration_foreign_key(extras \\\\ []) when is_list(extras),\n      do: [type: :binary_id]"

      assert source =~ "[type: :timestamptz]"
    end

    test "ships migration_default_prefix, which apps kept adding by hand" do
      ExUnit.CaptureIO.capture_io(fn -> CompiledConfig.run([]) end)

      assert File.read!("config/defdo_compiled_config.exs") =~ "def migration_default_prefix"
    end

    test "guards against redefining a module a dependency already provides" do
      ExUnit.CaptureIO.capture_io(fn -> CompiledConfig.run([]) end)

      assert File.read!("config/defdo_compiled_config.exs") =~
               "unless Code.ensure_loaded?(Defdo.Repo.CompileConfig) do"
    end

    test "what it generates passes its own drift check" do
      ExUnit.CaptureIO.capture_io(fn -> CompiledConfig.run([]) end)

      assert Audit.check_compiled_config("config") == []
    end
  end

  describe "not clobbering" do
    test "an existing file is left alone and explained" do
      File.mkdir_p!("config")
      File.write!("config/compiled_test.exs", "# hand-edited\n")

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          CompiledConfig.run(["--filename", "compiled_test"])
        end)

      assert output =~ "already exists and was left alone"
      assert File.read!("config/compiled_test.exs") == "# hand-edited\n"
    end

    test "--force regenerates it" do
      File.mkdir_p!("config")
      File.write!("config/compiled_test.exs", "# hand-edited\n")

      ExUnit.CaptureIO.capture_io(fn ->
        CompiledConfig.run(["--filename", "compiled_test", "--force"])
      end)

      assert File.read!("config/compiled_test.exs") =~ "defmodule Defdo.Repo.CompileConfig do"
    end
  end

  describe "--check" do
    test "reports nothing when there is no flavour file" do
      assert ExUnit.CaptureIO.capture_io(fn -> CompiledConfig.run(["--check"]) end) =~
               "no drift found"
    end

    test "exits 1 on the timestamptz key drift" do
      File.mkdir_p!("config")

      File.write!("config/compiled_test.exs", ~S'''
      defmodule Defdo.Repo.CompileConfig do
        def migration_primary_key(extras \\ []) when is_list(extras), do: [type: :timestamptz] ++ extras
      end
      ''')

      assert catch_exit(
               ExUnit.CaptureIO.capture_io(:stderr, fn -> CompiledConfig.run(["--check"]) end)
             ) == {:shutdown, 1}
    end
  end

  describe "filename validation" do
    test "rejects an extension that is not .exs" do
      assert_raise Mix.Error, ~r/Only .exs extension/, fn ->
        CompiledConfig.run(["--filename", "config.ex"])
      end
    end
  end
end
