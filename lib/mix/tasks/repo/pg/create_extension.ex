defmodule Mix.Tasks.Defdo.Repo.Pg.CreateExtension do
  @moduledoc """
  Initialize a new schema in postgres, for convenience it uses psql

  Before you start to code in our sass flow we require to create a custom schema.

  Remember that you can put an alias to ensure that you have it before run migrations.
  """
  use Mix.Task
  require Logger

  def run([]), do: error()

  def run(args) do
    valid_options = [name: :string, repo: :string, debug: :boolean, otp_app: :string]

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
    |> create_extensions(opts[:name], opts)
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

  def create_extensions(repo, extension, opts) when is_bitstring(extension) do
    extensions = String.split(extension, ",", trim: true)
    create_extensions(repo, extensions, opts)
  end

  def create_extensions(repo, extensions, opts) when is_atom(repo) when is_list(extensions) do
    config = get_config(repo, opts)

    statements =
      extensions
      |> Enum.map(&"CREATE EXTENSION IF NOT EXISTS #{&1};")
      |> Enum.join(" ")

    if opts[:debug] do
      Logger.debug(["Config is ", inspect(config)])
    end

    """
    export PGPASSWORD=#{config[:password]};
    psql -U #{config[:username]} -h #{config[:hostname]} -d #{config[:database]} \
      -c "#{statements}"
    """
    |> Mix.shell().cmd()
  end

  defp get_config(repo, opts) when is_atom(repo) do
    otp_app = (opts[:otp_app] || otp_app()) |> safe_atom()

    if opts[:debug] do
      Logger.debug([
        "The otp_app ",
        inspect(otp_app),
        " and the repo ",
        inspect(repo)
      ])
    end

    Application.get_env(otp_app, repo)
  end

  def otp_app do
    module = Mix.Project.get()
    apply(module, :project, [])[:app]
  end

  defp error do
    Mix.raise("""
    Invalid arguments to defdo.repo.pg.create_extension, expected:
        mix defdo.repo.pg.create_extension --name citext --repo Defdo.App.Repo
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
