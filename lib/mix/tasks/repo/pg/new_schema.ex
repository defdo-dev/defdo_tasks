defmodule Mix.Tasks.Defdo.Repo.Pg.NewSchema do
  @moduledoc """
  Initialize a new schema in postgres, for convenience it uses psql

  Before you start to code in our sass flow we require to create a custom schema.

  Remember that you can put an alias to ensure that you have it before run migrations.
  """
  use Mix.Task
  require Logger

  def run([]), do: error()

  def run(args) do
    valid_options = [schema: :string, repo: :string, debug: :boolean, otp_app: :string]

    case OptionParser.parse(args, strict: valid_options) do
      {opts, [], []} ->
        new(opts)

      {_, _, _} ->
        error()
    end
  end

  defp new(opts) do
    repo = opts[:repo]

    [repo]
    |> Module.safe_concat()
    |> create_schemas(opts[:schema], opts)
  rescue
    ArgumentError ->
      repo = opts[:repo]
      otp_app = opts[:otp_app] || otp_app()

      Mix.raise("""
      Ensure that you have the repo configuration for #{repo}:

      config #{otp_app}, #{repo},
        username: "postgres",
        password: "postgres",
        hostname: "localhost",
        database: "#{otp_app}_dev",
      """)
  end

  def create_schemas(repo, schema, opts) when is_bitstring(schema) do
    schemas = String.split(schema, ",")
    create_schemas(repo, schemas, opts)
  end

  def create_schemas(repo, schemas, opts) when is_atom(repo) when is_list(schemas) do
    config = get_config(repo, opts)

    schema_statements =
      schemas
      |> Enum.map(&"CREATE SCHEMA IF NOT EXISTS #{&1};")
      |> Enum.join(" ")

    if opts[:debug] do
      Logger.debug(["Config is ", inspect(config)])
    end

    """
    export PGPASSWORD=#{config[:password]};
    psql -U #{config[:username]} -h #{config[:hostname]} -d #{config[:database]} \
      -c "#{schema_statements}"
    """
    |> Mix.shell().cmd()
  end

  defp get_config(repo, opts) when is_atom(repo) do
    otp_app = opts[:otp_app] || otp_app()
    Application.get_env(safe_atom(otp_app), repo)
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

  defp safe_atom(term) when is_atom(term), do: term

  defp safe_atom(term) do
    String.to_existing_atom(term)
  rescue
    ArgumentError ->
      String.to_atom(term)
  end
end
