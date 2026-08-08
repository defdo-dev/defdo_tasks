defmodule Defdo.Tasks.Repo.Extensions do
  @moduledoc """
  Declarative precheck for Postgres extensions a repo's migrations depend on.

  A fresh database migrated with a bare `mix ecto.migrate` dies with a raw
  driver error when a migration needs an extension the database does not have:

      ** (Postgrex.Error) ERROR 42704 (undefined_object) type "citext" does not exist

  The provisioning edge already exists — `mix defdo.repo.pg.create_extension`
  (see `Mix.Tasks.Defdo.Repo.Pg.CreateExtension`) — but paths that bypass the
  `ecto.setup` alias (bare `ecto.migrate`, a host adopting a library's
  migrations, CI images) never run it. This helper lets a library or host
  *declare* what the database must provide and fail fast, before the DDL
  explodes mid-migration-chain, with an actionable message instead of a raw
  driver error.

  ## As a migrator precheck

  This is a plain function taking a repo plus opts, so a migrator (for example
  `Defdo.Tenant.Migrator`) can invoke it before running any version:

      # a migrator that carries `required_extensions: ["citext"]`
      Defdo.Tasks.Repo.Extensions.ensure!(repo, required_extensions,
        otp_app: :defdo_auth,
        create_extensions: create?
      )

  It queries the live connection through the repo's Ecto SQL adapter, so it runs
  the same in `mix ecto.migrate` and in a release's `Release.migrate/0` (it
  raises a plain exception, never `Mix.raise`, so it is safe where Mix is
  stripped). Ecto is resolved at runtime, so this package keeps its lean,
  `runtime: false` dependency surface.

  ## Precheck-first, opt in to create

  By default `ensure!/3` only prechecks and raises with the remediation
  command. `CREATE EXTENSION` needs elevated rights that production migration
  roles often lack; with `create_extensions: true` it attempts
  `CREATE EXTENSION IF NOT EXISTS` first (dev/docker roles have the rights) and
  falls back to the actionable error when the role cannot — the raw
  insufficient-privilege error never leaks.

  ## Safety

  Extension names are SQL identifiers and cannot be bound parameters in DDL, so
  `valid_name?/1` restricts them to a conservative identifier charset before any
  name reaches a statement.
  """

  alias Defdo.Tasks.Repo.Psql

  @name_regex ~r/\A[a-zA-Z_][a-zA-Z0-9_-]*\z/
  @max_identifier_length 63

  defmodule MissingExtensionError do
    @moduledoc """
    Raised by `Defdo.Tasks.Repo.Extensions.ensure!/3` when a required extension
    is absent (and could not be created). `:missing` holds the extension names.
    """
    defexception [:message, :missing]
  end

  @typedoc "One or more extension names, as a list or a comma-separated string."
  @type extensions :: String.t() | [String.t()]

  @doc """
  Ensures every extension in `extensions` is present in `repo`'s database.

  Returns `:ok` when all are present. Raises `MissingExtensionError` naming the
  missing extensions and the exact remediation command otherwise. Raises
  `ArgumentError` when an extension name is not a valid identifier.

  ## Options

    * `:otp_app` — the OTP app that owns the repo, named in the error and
      remediation command. Defaults to `--otp-app` / the current Mix project.
    * `:create_extensions` — when `true`, attempt `CREATE EXTENSION IF NOT
      EXISTS` for each missing extension before failing, and only raise for the
      ones the role could not create.
    * `:installed_fun` — `(repo -> {:ok, [name]} | {:error, term})`, overrides
      how installed extensions are read (defaults to querying `pg_extension`).
    * `:create_fun` — `(repo, name -> :ok | {:error, :insufficient_privilege |
      term})`, overrides how an extension is created.
  """
  @spec ensure!(module(), extensions(), keyword()) :: :ok
  def ensure!(repo, extensions, opts \\ []) when is_atom(repo) do
    names = extensions |> normalize() |> validate_names!()
    otp_app = otp_app(opts)

    installed_fun = opts[:installed_fun] || (&default_installed/1)
    create_fun = opts[:create_fun] || (&default_create/2)

    missing = names -- installed!(repo, installed_fun)

    missing =
      if missing != [] and opts[:create_extensions] do
        Enum.reject(missing, &create_ok?(create_fun, repo, &1))
      else
        missing
      end

    case missing do
      [] ->
        :ok

      still_missing ->
        raise MissingExtensionError,
          missing: still_missing,
          message: format_missing_error(still_missing, repo, otp_app)
    end
  end

  @doc """
  Validates a list of extension names, returning it unchanged.

  Raises `ArgumentError` on the first invalid name. See `valid_name?/1`.
  """
  @spec validate_names!([String.t()]) :: [String.t()]
  def validate_names!(names) when is_list(names) do
    Enum.each(names, fn name ->
      unless valid_name?(name) do
        raise ArgumentError, """
        invalid Postgres extension name: #{inspect(name)}

        Extension names are SQL identifiers; only letters, digits, underscores
        and hyphens are allowed (starting with a letter or underscore).
        """
      end
    end)

    names
  end

  @doc """
  Whether `name` is a safe Postgres extension identifier.

      iex> Defdo.Tasks.Repo.Extensions.valid_name?("citext")
      true

      iex> Defdo.Tasks.Repo.Extensions.valid_name?("pg_trgm")
      true

      iex> Defdo.Tasks.Repo.Extensions.valid_name?("uuid-ossp")
      true

      iex> Defdo.Tasks.Repo.Extensions.valid_name?("citext; DROP TABLE users")
      false

      iex> Defdo.Tasks.Repo.Extensions.valid_name?("")
      false
  """
  @spec valid_name?(term()) :: boolean()
  def valid_name?(name) when is_binary(name) do
    String.length(name) <= @max_identifier_length and Regex.match?(@name_regex, name)
  end

  def valid_name?(_name), do: false

  @doc """
  The `mix defdo.repo.pg.create_extension` command that provisions `missing`.

      iex> Defdo.Tasks.Repo.Extensions.remediation_command(["citext"], Defdo.Auth.Repo, :defdo_auth)
      "mix defdo.repo.pg.create_extension --name citext --repo Defdo.Auth.Repo --otp-app defdo_auth"

      iex> Defdo.Tasks.Repo.Extensions.remediation_command(["citext", "pg_trgm"], Defdo.Auth.Repo, :defdo_auth)
      "mix defdo.repo.pg.create_extension --name citext,pg_trgm --repo Defdo.Auth.Repo --otp-app defdo_auth"
  """
  @spec remediation_command([String.t()], module(), atom()) :: String.t()
  def remediation_command(missing, repo, otp_app) do
    "mix defdo.repo.pg.create_extension --name #{Enum.join(missing, ",")}" <>
      " --repo #{inspect(repo)} --otp-app #{otp_app}"
  end

  @doc """
  The full actionable error message for `missing` extensions.
  """
  @spec format_missing_error([String.t()], module(), atom()) :: String.t()
  def format_missing_error(missing, repo, otp_app) do
    noun = if length(missing) == 1, do: "extension", else: "extensions"
    listed = missing |> Enum.map_join(", ", &~s("#{&1}"))

    """
    database is missing #{noun} #{listed} required by #{otp_app}.
    Run: #{remediation_command(missing, repo, otp_app)}
    (or grant the migration role rights and pass create_extensions: true)\
    """
  end

  defp normalize(extensions) when is_binary(extensions), do: Psql.split(extensions)
  defp normalize(extensions) when is_list(extensions), do: extensions

  defp otp_app(opts), do: opts[:otp_app] || Psql.otp_app(opts)

  defp create_ok?(create_fun, repo, name) do
    case create_fun.(repo, name) do
      :ok -> true
      {:error, _reason} -> false
    end
  end

  defp installed!(repo, fun) do
    case fun.(repo) do
      {:ok, list} when is_list(list) ->
        list

      {:error, reason} ->
        raise "failed to read installed Postgres extensions for #{inspect(repo)}: " <>
                inspect(reason)
    end
  end

  defp default_installed(repo) do
    case run_sql(repo, "SELECT extname FROM pg_extension") do
      {:ok, %{rows: rows}} -> {:ok, List.flatten(rows)}
      {:error, _reason} = error -> error
    end
  end

  defp default_create(repo, name) do
    # `name` is validated by `validate_names!/1` before it reaches here; the
    # identifier is still double-quoted so a hyphenated name like "uuid-ossp"
    # is a legal statement.
    case run_sql(repo, ~s(CREATE EXTENSION IF NOT EXISTS "#{name}")) do
      {:ok, _result} -> :ok
      {:error, %{postgres: %{code: :insufficient_privilege}}} -> {:error, :insufficient_privilege}
      {:error, reason} -> {:error, reason}
    end
  end

  # Resolve Ecto at runtime so this package keeps a `runtime: false`, Ecto-free
  # dependency surface and compiles without the module present. Dynamic dispatch
  # on a computed module (not a literal `apply/3`) keeps both the compiler and
  # Credo quiet about the optional dependency.
  defp run_sql(repo, sql) do
    adapter = sql_adapter()
    adapter.query(repo, sql, [])
  end

  defp sql_adapter, do: Module.concat(["Ecto", "Adapters", "SQL"])
end
