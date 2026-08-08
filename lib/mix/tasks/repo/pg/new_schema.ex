defmodule Mix.Tasks.Defdo.Repo.Pg.NewSchema do
  @shortdoc "Creates Postgres schemas for a defdo app"

  @moduledoc """
  Creates one or more Postgres schemas, using `psql`.

      mix defdo.repo.pg.new_schema --schema my_app --repo Defdo.App.Repo
      mix defdo.repo.pg.new_schema --schema my_app,defdo_vault --repo Defdo.App.Repo

  defdo apps partition a shared database by schema, so the schema has to exist
  before migrations run. Add this to your `ecto.setup` alias rather than
  remembering to run it.

  ## Options

    * `--schema` — comma-separated schema names (required)
    * `--repo` — the Ecto repo module to read connection settings from (required)
    * `--otp-app` — the OTP app holding that repo's config, defaults to the
      current project
    * `--debug` — log the resolved config and repo
  """
  use Mix.Task

  alias Defdo.Tasks.Repo.Psql

  @impl Mix.Task
  def run([]), do: error()

  def run(args) do
    valid_options = [schema: :string, repo: :string, debug: :boolean, otp_app: :string]

    case OptionParser.parse(args, strict: valid_options) do
      {opts, [], []} -> new(opts)
      {_, _, _} -> error()
    end
  end

  defp new(opts) do
    opts
    |> Psql.repo!()
    |> create_schemas(opts[:schema] || error(), opts)
  end

  @doc """
  Creates the given schemas. Accepts a comma-separated string or a list.

  Empty entries are dropped: `--schema "my_app,"` used to emit
  `CREATE SCHEMA IF NOT EXISTS ;`, which psql rejects with a syntax error that
  says nothing about the trailing comma.
  """
  def create_schemas(repo, schema, opts) when is_bitstring(schema) do
    create_schemas(repo, Psql.split(schema), opts)
  end

  def create_schemas(repo, schemas, opts) when is_atom(repo) and is_list(schemas) do
    config = Psql.config!(repo, opts)

    schemas
    |> Enum.map_join(" ", &"CREATE SCHEMA IF NOT EXISTS #{&1};")
    |> then(&Psql.command(config, &1))
    |> Mix.shell().cmd()
  end

  defp error do
    Mix.raise("""
    Invalid arguments to defdo.repo.pg.new_schema, expected:

        mix defdo.repo.pg.new_schema --schema defdo_apps --repo Defdo.App.Repo
    """)
  end
end
