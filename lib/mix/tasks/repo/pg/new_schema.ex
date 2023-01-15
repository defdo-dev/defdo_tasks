defmodule Mix.Tasks.Defdo.Repo.Pg.NewSchema do
  @moduledoc """
  Initialize a new schema in postgres, for convenience it uses psql

  Before you start to code in our sass flow we require to create a custom schema.

  Remember that you can put an alias to ensure that you have it before run migrations.
  """
  use Mix.Task

  def run([]), do: error()
  def run(args) do
    valid_options = [schema: :string, repo: :string]

    case OptionParser.parse_head!(args, strict: valid_options) do
      {[schema: schema, repo: repo], []} ->
        new(schema, repo)

      {_, _} ->
        error()
    end
  end

  defp new(schema, repo) when is_bitstring(schema) do
      [repo]
      |> Module.safe_concat()
      |> create_schemas(schema)

    rescue
      ArgumentError ->
        otp_app = otp_app()
        Mix.raise("""
        Ensure that you have the repo configuration for #{repo}:

        config #{otp_app}, #{repo},
          username: "postgres",
          password: "postgres",
          hostname: "localhost",
          database: "#{otp_app}_dev",
        """)
  end

  def create_schemas(repo, schema) when is_bitstring(schema) do
    schemas = String.split(schema, ",")
    create_schemas(repo, schemas)
  end

  def create_schemas(repo, schemas) when is_atom(repo) when is_list(schemas) do
    config = get_config(repo)

    schema_statements =
      schemas
      |> Enum.map(&("CREATE SCHEMA IF NOT EXISTS #{&1};"))
      |> Enum.join(" ")

    """
    export PGPASSWORD=#{config[:password]};
    psql -U #{config[:username]} -h #{config[:hostname]} -d #{config[:database]} \
      -c "#{schema_statements}"
    """
    |> Mix.shell().cmd()
  end

  defp get_config(repo) when is_atom(repo) do
    Application.get_env(otp_app(), repo)
  end

  def otp_app do
    module = Mix.Project.get()
    apply(module, :project, [])[:app]
  end

  defp error do
    Mix.raise("""
      Invalid arguments to defdo.repo.pg.new_schema, expected:
          mix defdo.repo.pg.new_schema --schema defdo_apps --repo Defdo.App.Repo
      """)
  end
end
