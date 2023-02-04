defmodule Mix.Tasks.Defdo.Repo.CompiledConfig do
  @moduledoc """
  Creates the apps_runtime config file.
  """
  @shortdoc "Generates a flavour compiled config file"

  use Mix.Task

  def run(args) do
    valid_options = [filename: :string]

    case OptionParser.parse_head!(args, switches: valid_options) do
      {opts, []} ->
        new(opts[:filename])

      {_, _} ->
        error()
    end
  end

  def new(nil), do: new("defdo_compiled_config.exs")

  def new(filename) do
    config_dir = config_dir()
    buffer = compiled_config()
    filename = ensure_extension(filename)
    path = Path.join(config_dir, filename)
    File.write!(path, buffer)
    hint(filename)
  end

  defp ensure_extension(filename) do
    case Path.extname(filename) do
      "" ->
        "#{filename}.exs"

      ".exs" ->
        filename

      _ ->
        Mix.raise("""
        Only .exs extension is allowed for the filename.

        Your provide the filename: `#{filename}` which is not a valid name.
        """)
    end
  end

  defp compiled_config do
    ~S'defmodule Defdo.Repo.CompileConfig do
  @moduledoc """
  Provide a flavour to configure repo options for defdo apps.
  """
  def schema(name \\ otp_app()),
    # If you whish to use another schema for your deployment
    # just give the schema to use through and environment variable.
    do: System.get_env("TENANT_APP_SCHEMA", "#{name}")

  def after_connect(extra_schemas \\ [])
  def after_connect(extra_schemas) when is_bitstring(extra_schemas), do:
    extra_schemas |> String.split(",") |> after_connect()

  def after_connect(extra_schemas) when is_list(extra_schemas) do
    search_path =
      Enum.join(([schema() | extra_schemas] ++ ~w(public)), ",")

    {Postgrex, :query!, ["SET search_path TO #{search_path}", []]}
  end

  def migration_source(schema \\ "") when is_bitstring(schema) do
    ["schema_migrations", schema]
    |> Enum.reject(& &1 == "")
    |> Enum.join("_")
  end

  def migration_timestamps(extras \\ []) when is_list(extras), do:
    [type: :timestamptz] ++ extras

  def migration_primary_key(extras \\ []) when is_list(extras), do:
    [type: :binary_id] ++ extras

  def migration_foreign_key(extras \\ []) when is_list(extras), do:
    [type: :binary_id] ++ extras

  def otp_app do
    module = Mix.Project.get()
    apply(module, :project, [])[:app]
  end
end'
  end

  def config_dir do
    {:ok, filename} = Mix.Project.config()[:config_path] |> Path.safe_relative_to(".")
    config_dir = filename |> Path.dirname()

    if File.dir?(config_dir) do
      config_dir
    else
      File.mkdir_p(config_dir)
      config_dir
    end
  end

  def hint(filename) do
    Mix.shell().info("""
    Update your config/config.exs with the following information

    import_config "#{filename}"
    alias Defdo.Repo.CompileConfig, as: RepoCompileConfig

      # Use a flavored flow within schema
      config :#{otp_app()}, MyApp.Repo,
        migration_source: RepoCompileConfig.migration_source(),
        migration_timestamps: RepoCompileConfig.migration_timestamps(),
        migration_primary_key: RepoCompileConfig.migration_primary_key(),
        migration_foreign_key: RepoCompileConfig.migration_foreign_key(),
        after_connect: RepoCompileConfig.after_connect()
    """)
  end

  defp error do
    Mix.raise("""
    Invalid arguments to defdo.repo.helper, expects one of:

        mix defdo.repo.compiled_config
        mix defdo.repo.compiled_config --filename extra_config
        mix defdo.repo.compiled_config --filename extra_config.exs
    """)
  end

  defp otp_app do
    module = Mix.Project.get()
    apply(module, :project, [])[:app]
  end
end
