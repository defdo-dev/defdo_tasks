defmodule Defdo.Tasks.Repo.Psql do
  @moduledoc """
  Shared plumbing for the `defdo.repo.pg.*` tasks.

  Both tasks resolve an Ecto repo's configuration and shell out to `psql`. They
  used to do it with two copies of the same code, which is how one of them
  gained `--port` support and the other did not, and how one of them trimmed
  empty names out of its comma-separated list and the other did not.
  """

  require Logger

  @doc """
  Resolves the Ecto repo configuration for a repo module.

  Raises with the configuration the caller is missing rather than returning
  `nil`. The previous behaviour let `nil` flow into string interpolation, so a
  missing config produced `psql -U  -h  -d ` and a confusing psql error instead
  of an actionable one.
  """
  @spec config!(module(), keyword()) :: keyword()
  def config!(repo, opts) when is_atom(repo) do
    otp_app = otp_app(opts)

    if opts[:debug] do
      Logger.debug(["The otp_app ", inspect(otp_app), " and the repo ", inspect(repo)])
    end

    case Application.get_env(otp_app, repo) do
      nil ->
        Mix.raise("""
        No configuration found for #{inspect(repo)} under the #{inspect(otp_app)} application.

        Add it to your config, or pass the right app with --otp-app:

            config #{inspect(otp_app)}, #{inspect(repo)},
              username: "postgres",
              password: "postgres",
              hostname: "localhost",
              port: 5432,
              database: "#{otp_app}_dev"
        """)

      config when is_list(config) ->
        if opts[:debug], do: Logger.debug(["Config is ", inspect(config)])
        config
    end
  end

  @doc """
  Resolves a repo module from the `--repo` string.

  `Module.safe_concat/1` only resolves an already-existing atom, so this raises
  with the configuration hint when the module is unknown.
  """
  @spec repo!(keyword()) :: module()
  def repo!(opts) do
    case opts[:repo] do
      nil ->
        Mix.raise("--repo is required, for example --repo Defdo.App.Repo")

      repo ->
        Module.safe_concat([repo])
    end
  rescue
    ArgumentError ->
      Mix.raise("""
      Unknown repo #{inspect(opts[:repo])}.

      `--repo` must name a module that exists in this project. Make sure the project
      compiles and that the repo is configured for #{inspect(otp_app(opts))}.
      """)
  end

  @doc """
  Splits a comma-separated CLI value, dropping empties.

      iex> Defdo.Tasks.Repo.Psql.split("a, b ,, c")
      ["a", "b", "c"]

      iex> Defdo.Tasks.Repo.Psql.split("")
      []
  """
  @spec split(String.t()) :: [String.t()]
  def split(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  @doc """
  Builds the shell command that runs `statements` through `psql`.

  The port is read from the repo config with the Postgres default as a
  fallback — both tasks now do this, which was not true before.
  """
  @spec command(keyword(), String.t()) :: String.t()
  def command(config, statements) do
    port = config[:port] || 5432

    """
    export PGPASSWORD=#{config[:password]};
    psql -U #{config[:username]} -h #{config[:hostname]} -d #{config[:database]} -p #{port} \
      -c "#{statements}"
    """
  end

  @doc """
  The OTP app to read repo configuration from: `--otp-app` when given, otherwise
  the current Mix project's `:app`.
  """
  @spec otp_app(keyword()) :: atom()
  def otp_app(opts) do
    case opts[:otp_app] do
      nil -> current_otp_app()
      app when is_atom(app) -> app
      app -> safe_atom(app)
    end
  end

  @doc "The `:app` of the current Mix project."
  @spec current_otp_app() :: atom() | nil
  def current_otp_app do
    case Mix.Project.get() do
      nil -> nil
      module -> apply(module, :project, [])[:app]
    end
  end

  defp safe_atom(term) when is_atom(term), do: term

  defp safe_atom(term) do
    String.to_existing_atom(term)
  rescue
    ArgumentError -> String.to_atom(term)
  end
end
