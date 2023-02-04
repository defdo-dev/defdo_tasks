defmodule Defdo.Tasks.RepoPgCreateExtensionTest do
  @moduledoc false
  use ExUnit.Case, async: true

  defmodule RepoTest do
    @moduledoc false
  end

  test "create test to db " do
    assert ExUnit.CaptureIO.capture_io(fn ->
             assert Mix.Task.rerun("defdo.repo.pg.create_extension", [
                      "--name",
                      "citext",
                      "--repo",
                      "RepoTest"
                    ])
           end) =~ "CREATE EXTENSION IF NOT EXISTS citext;"

    assert ExUnit.CaptureIO.capture_io(fn ->
             assert Mix.Task.rerun("defdo.repo.pg.create_extension", [
                      "--name",
                      "citext,pg_search",
                      "--repo",
                      "RepoTest"
                    ])
           end) =~
             "CREATE EXTENSION IF NOT EXISTS citext; CREATE EXTENSION IF NOT EXISTS pg_search;"
  end
end
