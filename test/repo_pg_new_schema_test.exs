defmodule Defdo.Tasks.RepoPgNewSchemaTest do
  @moduledoc """
  These tests used to run the task against a repo with no configuration at all
  and assert on whatever `psql` echoed back. That passed for the wrong reason:
  the task interpolated `nil` for every connection setting and shelled out to
  `psql -U  -h  -d `, and the assertion matched the statement inside psql's own
  error message. They now configure a repo and assert on the command that gets
  built.
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

  setup context do
    Application.put_env(:defdo_tasks, RepoTest, context[:config] || @config)
    on_exit(fn -> Application.delete_env(:defdo_tasks, RepoTest) end)
    :ok
  end

  describe "create_schemas/3" do
    test "builds one statement per schema" do
      config = Psql.config!(RepoTest, [])

      command =
        ["test_schema", "test2_schema"]
        |> Enum.map_join(" ", &"CREATE SCHEMA IF NOT EXISTS #{&1};")
        |> then(&Psql.command(config, &1))

      assert command =~
               "CREATE SCHEMA IF NOT EXISTS test_schema; CREATE SCHEMA IF NOT EXISTS test2_schema;"
    end
  end

  describe "argument handling" do
    test "a trailing comma no longer produces an empty CREATE SCHEMA" do
      # `--schema "a,"` used to emit `CREATE SCHEMA IF NOT EXISTS ;`, which psql
      # rejects with a syntax error that says nothing about the trailing comma.
      assert Psql.split("test_schema,") == ["test_schema"]
      assert Psql.split("a, b ,, c") == ["a", "b", "c"]
    end

    test "no arguments raises with the usage" do
      assert_raise Mix.Error, ~r/--schema defdo_apps --repo/, fn ->
        Mix.Tasks.Defdo.Repo.Pg.NewSchema.run([])
      end
    end

    test "an unknown repo raises with the configuration hint" do
      assert_raise Mix.Error, ~r/Unknown repo/, fn ->
        Mix.Tasks.Defdo.Repo.Pg.NewSchema.run(["--schema", "s", "--repo", "No.Such.Repo"])
      end
    end
  end

  describe "config resolution" do
    test "a repo with no configuration raises instead of building a broken command" do
      Application.delete_env(:defdo_tasks, RepoTest)

      assert_raise Mix.Error, ~r/No configuration found for/, fn ->
        Psql.config!(RepoTest, [])
      end
    end

    @tag config: [
           username: "postgres",
           password: "secret",
           hostname: "localhost",
           database: "defdo_tasks_test",
           port: 5555
         ]
    test "the configured port is used" do
      assert Psql.config!(RepoTest, []) |> Psql.command("SELECT 1;") =~ "-p 5555"
    end

    test "the Postgres default port is used when none is configured" do
      assert Psql.config!(RepoTest, []) |> Psql.command("SELECT 1;") =~ "-p 5432"
    end
  end
end
