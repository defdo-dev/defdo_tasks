defmodule Defdo.Tasks.RepoCompiledConfigTest do
  @moduledoc false
  use ExUnit.Case, async: true

  test "install compiled config " do
    assert ExUnit.CaptureIO.capture_io(fn ->
             assert Mix.Task.rerun("defdo.repo.compiled_config", ["--filename", "compiled_test"])
           end) =~ "import_config \"compiled_test.exs\""

    assert File.exists?("config/compiled_test.exs")
    assert File.read!("config/compiled_test.exs") =~ "defmodule Defdo.Repo.CompileConfig do"

    assert ExUnit.CaptureIO.capture_io(fn ->
             assert Mix.Task.rerun("defdo.repo.compiled_config", [])
           end) =~ "import_config \"defdo_compiled_config.exs\""

    assert File.exists?("config/defdo_compiled_config.exs")
    assert File.read!("config/defdo_compiled_config.exs") =~ "defmodule Defdo.Repo.CompileConfig do"

    # cleanup
    assert :ok = File.rm("config/compiled_test.exs")
    assert :ok = File.rm("config/defdo_compiled_config.exs")
  end
end
