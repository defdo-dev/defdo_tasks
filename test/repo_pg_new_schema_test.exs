defmodule Defdo.Tasks.RepoPgNewSchemaTest do
  @moduledoc false
  use ExUnit.Case, async: true

  defmodule RepoTest do
    @moduledoc false
  end

  test "create test to db " do
    assert ExUnit.CaptureIO.capture_io(fn ->
             assert Mix.Task.rerun("defdo.repo.pg.new_schema", [
                      "--schema",
                      "test_schema",
                      "--repo",
                      "RepoTest"
                    ])
           end) =~ "CREATE SCHEMA IF NOT EXISTS test_schema;"

    assert ExUnit.CaptureIO.capture_io(fn ->
             assert Mix.Task.rerun("defdo.repo.pg.new_schema", [
                      "--schema",
                      "test_schema,test2_schema",
                      "--repo",
                      "RepoTest"
                    ])
           end) =~
             "CREATE SCHEMA IF NOT EXISTS test_schema; CREATE SCHEMA IF NOT EXISTS test2_schema;"
  end
end
