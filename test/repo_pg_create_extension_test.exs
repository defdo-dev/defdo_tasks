defmodule Defdo.Tasks.RepoPgCreateExtensionTest do
  @moduledoc """
  See the note in `Defdo.Tasks.RepoPgNewSchemaTest` about why these no longer
  run against an unconfigured repo.
  """
  use ExUnit.Case, async: false

  alias Defdo.Tasks.Repo.Psql

  defmodule RepoTest do
    @moduledoc false
  end

  @config [
    username: "postgres",
    password: "secret",
    hostname: "localhost",
    database: "defdo_tasks_test"
  ]

  setup do
    Application.put_env(:defdo_tasks, RepoTest, @config)
    on_exit(fn -> Application.delete_env(:defdo_tasks, RepoTest) end)
    :ok
  end

  describe "create_extensions/3" do
    test "builds one statement per extension" do
      config = Psql.config!(RepoTest, [])

      command =
        ["citext", "pg_trgm"]
        |> Enum.map_join(" ", &"CREATE EXTENSION IF NOT EXISTS #{&1};")
        |> then(&Psql.command(config, &1))

      assert command =~
               "CREATE EXTENSION IF NOT EXISTS citext; CREATE EXTENSION IF NOT EXISTS pg_trgm;"
    end

    test "the port is honoured here too" do
      # `--port` support was added to defdo.repo.pg.new_schema and never to this
      # task, so it always connected on 5432. Both tasks share the builder now.
      Application.put_env(:defdo_tasks, RepoTest, Keyword.put(@config, :port, 6543))

      assert Psql.config!(RepoTest, []) |> Psql.command("SELECT 1;") =~ "-p 6543"
    end
  end

  describe "argument handling" do
    test "no arguments raises with the usage" do
      assert_raise Mix.Error, ~r/--name citext --repo/, fn ->
        Mix.Tasks.Defdo.Repo.Pg.CreateExtension.run([])
      end
    end

    test "an unknown repo raises with the configuration hint" do
      assert_raise Mix.Error, ~r/Unknown repo/, fn ->
        Mix.Tasks.Defdo.Repo.Pg.CreateExtension.run([
          "--name",
          "citext",
          "--repo",
          "No.Such.Repo"
        ])
      end
    end
  end
end
