defmodule Defdo.Tasks.Saas.MigratorChain do
  @moduledoc """
  The tenant migrator chain, and the trap it sets.

  `Defdo.Tenant.Migrator` versions 1..3 reach most apps *indirectly*: they are
  called from inside `defdo_vault`'s own version modules (`v2.ex`, `v4.ex` and
  `v7.ex` chain tenant v1, v2 and v3 respectively), so an app that runs the
  vault migrations gets tenant tables without ever writing a wrapper migration.

  Nothing carries version 4. An app that adopts `defdo_tenant` 0.11+ therefore
  gets a `Defdo.Tenant.Tenant.Schema.Profile` that selects `deleted_at` against
  a `tenant_profiles` table that has no such column, and every profile read
  fails with:

      column t0.deleted_at does not exist

  Three apps in the estate hit exactly that and each was repaired by hand.
  This module exists so a generated app never can, and so an existing app can
  be told the truth about itself by `mix defdo.saas.doctor`.

  ## Why the target version is probed, not hardcoded

  A constant `4` in this package would be correct until `defdo_tenant` ships v5,
  at which point this package would reproduce the very failure it prevents.
  `target_version/1` instead probes the migrator's version modules
  (`Defdo.Tenant.Migrator.V01`, `V02`, ...) and reports the highest one that is
  actually loadable, so the answer tracks the installed package.
  """

  @typedoc "How an app's migrations stand against the migrator's current version."
  @type status ::
          :current
          | {:behind, applied :: non_neg_integer(), target :: pos_integer()}
          | {:floating, files :: [String.t()]}
          | {:missing, target :: pos_integer()}
          | :unknown

  @typedoc """
  One wrapper migration found in a migrations directory.

  `:prefix` is the Postgres schema the wrapper targets: a literal string when
  the source names one, or `:dynamic` when it is computed at runtime (a config
  call, for instance) and therefore cannot be compared textually.
  """
  @type wrapper :: %{
          file: String.t(),
          up: pos_integer() | :floating,
          down: pos_integer() | :floating | nil,
          prefix: String.t() | :dynamic | nil
        }

  @default_migrator "Defdo.Tenant.Migrator"

  # Only used when the migrator module is not loadable at all -- for example
  # when this package's own tests run, or when the doctor is invoked before
  # `mix deps.get`. It is the floor of what is known to exist, never a claim
  # about what is installed.
  @known_floor 4

  @max_probe 99

  @doc "The migrator module a defdo SaaS app wraps by default."
  @spec default_migrator() :: String.t()
  def default_migrator, do: @default_migrator

  @doc """
  The highest migrator version that is actually available, by probing version
  modules until one does not load.

  Returns `{:ok, version}` when the migrator itself is loadable, or
  `{:assumed, #{@known_floor}}` when it is not — the caller should treat the
  latter as "cannot verify" rather than as fact.
  """
  @spec target_version(String.t()) :: {:ok, pos_integer()} | {:assumed, pos_integer()}
  def target_version(migrator \\ @default_migrator) when is_binary(migrator) do
    if loadable?(migrator) do
      {:ok, probe(migrator, 1, 0)}
    else
      {:assumed, @known_floor}
    end
  end

  defp loadable?(migrator) do
    Code.ensure_loaded?(Module.concat([migrator]))
  rescue
    ArgumentError -> false
  end

  defp probe(_migrator, index, highest) when index > @max_probe, do: highest

  defp probe(migrator, index, highest) do
    padded = String.pad_leading(to_string(index), 2, "0")
    module = Module.concat([migrator, "V#{padded}"])

    if Code.ensure_loaded?(module) do
      probe(migrator, index + 1, index)
    else
      highest
    end
  end

  @typedoc """
  How the migrator target version was resolved for an app, and against what.

    * `:version` — the target migrator version to compare wrappers against
    * `:source` — where that number was read: `:deps` (the resolved dependency's
      migrator source), `:lock` (mapped from `mix.lock`), or `:assumed` (neither
      was readable)
    * `:confidence` — `:resolved`, `:from_lock` or `:assumed`, tracking `:source`
    * `:dependency` — the OTP application the target was read from
    * `:dependency_version` — that dependency's version, so a caller sees *what*
      it was compared against rather than trusting a bare number; `nil` when the
      target was assumed
    * `:reason` — set only for `:assumed`, explaining why the number is a floor
      rather than a reading
  """
  @type resolution :: %{
          version: pos_integer(),
          source: :deps | :lock | :assumed,
          confidence: :resolved | :from_lock | :assumed,
          dependency: atom(),
          dependency_version: String.t() | nil,
          reason: String.t() | nil
        }

  # `defdo_tenant` version floors mapped to the highest migrator version they
  # ship, newest floor first. Verified against the estate: 0.10.5 carries
  # `current_version: 3`; 0.12.0 and 0.13.0 carry 4 -- v4 adds
  # `tenant_profiles.deleted_at`, which is why 0.11+ maps to 4. A locked version
  # below the lowest floor here is left unmapped so the resolver falls through to
  # `:assumed` rather than inventing a target for a version it does not know.
  @lock_targets [{"0.11.0", 4}, {"0.10.0", 3}]

  @doc """
  Resolves the migrator target version for the app at `root`, reporting where the
  number came from rather than assuming it.

  This is what `target_version/1` cannot do over stdio: that function probes
  *loaded* modules, and the MCP server runs in this package's process where
  `defdo_tenant` is never loaded, so it always answered `:assumed`. This reads
  the app's own tree instead. Resolution order:

    1. `:deps` — read `current_version` from the migrator source the app resolved
       (`<root>/deps/defdo_tenant/lib/defdo/migrator.ex`, or
       `<package_path>/lib/defdo/migrator.ex` when the app resolves it through a
       `path:` dependency and `:package_path` is given). Confidence `:resolved`.
    2. `:lock` — read the package version from `<root>/mix.lock` and map it to a
       known target. Confidence `:from_lock`.
    3. `:assumed` — neither is readable; fall back to the known floor (v#{@known_floor})
       and say so in `:reason`. Confidence `:assumed`.

  Options: `:package` (default `:defdo_tenant`), `:package_path` (the package root
  for a `path:`-resolved dependency) and `:migrator_source` (an explicit override
  of the migrator source file to read).
  """
  @spec resolve_target(String.t(), keyword()) :: resolution()
  def resolve_target(root, opts \\ []) when is_binary(root) do
    package = Keyword.get(opts, :package, :defdo_tenant)

    resolve_from_deps(root, package, opts) ||
      resolve_from_lock(root, package) ||
      assumed_resolution(root, package)
  end

  defp resolve_from_deps(root, package, opts) do
    with {:ok, source} <- File.read(migrator_source_path(root, package, opts)),
         version when is_integer(version) <- current_version_from_source(source) do
      %{
        version: version,
        source: :deps,
        confidence: :resolved,
        dependency: package,
        dependency_version: dependency_version(root, package, opts),
        reason: nil
      }
    else
      _not_readable -> nil
    end
  end

  defp resolve_from_lock(root, package) do
    with {:ok, lock} <- File.read(Path.join(root, "mix.lock")),
         version when is_binary(version) <- locked_version_from_source(lock, package),
         target when is_integer(target) <- target_for_locked_version(version) do
      %{
        version: target,
        source: :lock,
        confidence: :from_lock,
        dependency: package,
        dependency_version: version,
        reason: nil
      }
    else
      _not_readable -> nil
    end
  end

  defp assumed_resolution(root, package) do
    %{
      version: @known_floor,
      source: :assumed,
      confidence: :assumed,
      dependency: package,
      dependency_version: nil,
      reason:
        "could not read #{package}'s current_version from deps or mix.lock under " <>
          "#{root}; v#{@known_floor} is the last version this package knows about, " <>
          "not a reading of what the app has installed"
    }
  end

  defp migrator_source_path(root, package, opts) do
    cond do
      source = Keyword.get(opts, :migrator_source) ->
        source

      package_path = Keyword.get(opts, :package_path) ->
        Path.join([package_path, "lib", "defdo", "migrator.ex"])

      true ->
        Path.join([root, "deps", to_string(package), "lib", "defdo", "migrator.ex"])
    end
  end

  defp dependency_version(root, package, opts) do
    version_file =
      case Keyword.get(opts, :package_path) do
        nil -> Path.join([root, "deps", to_string(package), "VERSION"])
        package_path -> Path.join(package_path, "VERSION")
      end

    case File.read(version_file) do
      {:ok, contents} -> String.trim(contents)
      {:error, _reason} -> lock_version(root, package)
    end
  end

  defp lock_version(root, package) do
    case File.read(Path.join(root, "mix.lock")) do
      {:ok, lock} -> locked_version_from_source(lock, package)
      {:error, _reason} -> nil
    end
  end

  @doc """
  Reads `current_version` from a migrator module's source. Returns `nil` when the
  source declares none.

      iex> src = ~s|use Defdo.Migrator, control_table: "t", current_version: 4|
      iex> Defdo.Tasks.Saas.MigratorChain.current_version_from_source(src)
      4

      iex> Defdo.Tasks.Saas.MigratorChain.current_version_from_source("no version here")
      nil
  """
  @spec current_version_from_source(String.t()) :: pos_integer() | nil
  def current_version_from_source(source) when is_binary(source) do
    case Regex.run(~r/current_version:\s*(\d+)/, source) do
      [_all, version] -> String.to_integer(version)
      nil -> nil
    end
  end

  @doc """
  Reads a package's pinned version from `mix.lock` source. Returns `nil` when the
  package is not locked. The trailing `":` anchors the name so `defdo_tenant`
  never matches `defdo_tenant_plug`.

      iex> lock = ~s|  "defdo_tenant": {:hex, :defdo_tenant, "0.12.0", "abc", [:mix], [], "hexpm:defdo"},|
      iex> Defdo.Tasks.Saas.MigratorChain.locked_version_from_source(lock, :defdo_tenant)
      "0.12.0"

      iex> Defdo.Tasks.Saas.MigratorChain.locked_version_from_source("%{}", :defdo_tenant)
      nil
  """
  @spec locked_version_from_source(String.t(), atom()) :: String.t() | nil
  def locked_version_from_source(lock, package) when is_binary(lock) and is_atom(package) do
    name = Regex.escape(to_string(package))

    case Regex.run(~r/"#{name}":\s*\{:hex,\s*:#{name},\s*"([^"]+)"/, lock) do
      [_all, version] -> version
      nil -> nil
    end
  end

  @doc """
  Maps a `defdo_tenant` version to the highest migrator version it ships, or
  `nil` when the version is below the lowest floor this package knows about (so
  the resolver falls through to `:assumed` rather than guessing).

      iex> Defdo.Tasks.Saas.MigratorChain.target_for_locked_version("0.13.0")
      4

      iex> Defdo.Tasks.Saas.MigratorChain.target_for_locked_version("0.10.5")
      3

      iex> Defdo.Tasks.Saas.MigratorChain.target_for_locked_version("0.9.0")
      nil
  """
  @spec target_for_locked_version(String.t()) :: pos_integer() | nil
  def target_for_locked_version(version) when is_binary(version) do
    case Version.parse(version) do
      {:ok, parsed} -> target_at_or_above(parsed)
      :error -> nil
    end
  end

  defp target_at_or_above(parsed) do
    Enum.find_value(@lock_targets, fn {floor, target} ->
      if Version.compare(parsed, floor) != :lt, do: target
    end)
  end

  @doc """
  Finds every wrapper migration for `migrator` in a list of `{path, source}`
  pairs.

  Source is matched textually rather than by evaluating the migration, because
  the doctor must be able to read an app it cannot compile.

      iex> src = ~s|def up, do: Defdo.Tenant.Migrator.up(version: 4, prefix: "app")|
      iex> Defdo.Tasks.Saas.MigratorChain.scan([{"a.exs", src}])
      [%{file: "a.exs", up: 4, down: nil, prefix: "app"}]

  A call with no `version:` is reported as `:floating` — its behaviour is pinned
  to whatever version of the package happens to be installed when it first runs,
  so it applies a different schema in different environments.

      iex> src = ~s|def up, do: Defdo.Tenant.Migrator.up(prefix: "app")|
      iex> Defdo.Tasks.Saas.MigratorChain.scan([{"b.exs", src}])
      [%{file: "b.exs", up: :floating, down: nil, prefix: "app"}]

  A `@prefix` module attribute is resolved; anything computed is `:dynamic`.

      iex> src = ~s|@prefix "app"\\ndef up, do: Defdo.Tenant.Migrator.up(version: 4, prefix: @prefix)|
      iex> Defdo.Tasks.Saas.MigratorChain.scan([{"c.exs", src}]) |> hd() |> Map.get(:prefix)
      "app"

      iex> src = ~s|def up, do: Defdo.Tenant.Migrator.up(version: 4, prefix: MyApp.Config.prefix())|
      iex> Defdo.Tasks.Saas.MigratorChain.scan([{"d.exs", src}]) |> hd() |> Map.get(:prefix)
      :dynamic
  """
  @spec scan([{String.t(), String.t()}], String.t()) :: [wrapper()]
  def scan(files, migrator \\ @default_migrator) when is_list(files) do
    files
    |> Enum.map(fn {path, source} ->
      %{
        file: path,
        up: call_version(source, migrator, "up"),
        down: call_version(source, migrator, "down"),
        prefix: call_prefix(source, migrator)
      }
    end)
    |> Enum.reject(&(&1.up == nil and &1.down == nil))
  end

  defp call_prefix(source, migrator) do
    escaped = Regex.escape(migrator)

    case Regex.run(~r/#{escaped}\.up\([^)]*prefix:\s*([^,)\s]+)/, source) do
      [_all, "\"" <> _rest = literal] -> String.trim(literal, "\"")
      [_all, "@prefix"] -> attribute_prefix(source)
      [_all, _computed] -> :dynamic
      nil -> nil
    end
  end

  defp attribute_prefix(source) do
    case Regex.run(~r/@prefix\s+"([^"]+)"/, source) do
      [_all, literal] -> literal
      nil -> :dynamic
    end
  end

  defp call_version(source, migrator, fun) do
    escaped = Regex.escape(migrator)

    cond do
      captures = Regex.run(~r/#{escaped}\.#{fun}\(\s*version:\s*(\d+)/, source) ->
        captures |> List.last() |> String.to_integer()

      Regex.match?(~r/#{escaped}\.#{fun}\(/, source) ->
        :floating

      true ->
        nil
    end
  end

  @doc """
  Reads a migrations directory from disk and scans it. Missing directories scan
  as empty rather than raising, so the doctor works in a fresh project.
  """
  @spec scan_path(String.t(), String.t()) :: [wrapper()]
  def scan_path(dir, migrator \\ @default_migrator) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".exs"))
        |> Enum.sort()
        |> Enum.map(&{&1, File.read!(Path.join(dir, &1))})
        |> scan(migrator)

      {:error, _reason} ->
        []
    end
  end

  @doc """
  The highest version an app's wrappers actually apply, ignoring floating calls.

      iex> Defdo.Tasks.Saas.MigratorChain.applied_version([%{file: "a", up: 3, down: nil}, %{file: "b", up: 4, down: nil}])
      4

      iex> Defdo.Tasks.Saas.MigratorChain.applied_version([])
      0
  """
  @spec applied_version([wrapper()]) :: non_neg_integer()
  def applied_version(wrappers) do
    wrappers
    |> Enum.map(& &1.up)
    |> Enum.filter(&is_integer/1)
    |> Enum.max(fn -> 0 end)
  end

  @doc """
  Classifies an app against the migrator's target version.

  Floating wrappers win over everything else: an app whose schema depends on
  install order has a worse problem than an app that is merely behind.

      iex> Defdo.Tasks.Saas.MigratorChain.status([%{file: "a", up: 4, down: 4}], 4)
      :current

      iex> Defdo.Tasks.Saas.MigratorChain.status([%{file: "a", up: 3, down: 1}], 4)
      {:behind, 3, 4}

      iex> Defdo.Tasks.Saas.MigratorChain.status([], 4)
      {:missing, 4}

      iex> Defdo.Tasks.Saas.MigratorChain.status([%{file: "a", up: :floating, down: :floating}], 4)
      {:floating, ["a"]}
  """
  @spec status([wrapper()], pos_integer()) :: status()
  def status(wrappers, target) when is_list(wrappers) and is_integer(target) do
    floating = for w <- wrappers, w.up == :floating, do: w.file

    cond do
      floating != [] -> {:floating, floating}
      wrappers == [] -> {:missing, target}
      applied_version(wrappers) >= target -> :current
      true -> {:behind, applied_version(wrappers), target}
    end
  end

  @doc """
  Wrappers whose `down` does not undo exactly what their `up` did.

  `Defdo.Migrations.down/1` rolls back *down to and including* the version given,
  so a wrapper that runs `up(version: 4)` must run `down(version: 4)` to revert
  only its own step. `down(version: 3)` also reverts v3, which the wrapper never
  applied — one such wrapper exists in the estate today.

      iex> Defdo.Tasks.Saas.MigratorChain.asymmetric([%{file: "a", up: 4, down: 3}])
      [%{file: "a", up: 4, down: 3}]

      iex> Defdo.Tasks.Saas.MigratorChain.asymmetric([%{file: "a", up: 4, down: 4}])
      []
  """
  @spec asymmetric([wrapper()]) :: [wrapper()]
  def asymmetric(wrappers) do
    Enum.filter(wrappers, fn w ->
      is_integer(w.up) and is_integer(w.down) and w.up != w.down
    end)
  end

  @doc """
  Wrappers that target a different Postgres schema than `expected`.

  Two wrappers with different prefixes do not conflict in the migration runner —
  they succeed, and create two independent copies of `tenant_profiles` in two
  schemas. Which one the app reads then depends on the repo's `search_path`,
  which is exactly the kind of divergence that is invisible until it is not.

      iex> ws = [%{file: "a", up: 4, down: 4, prefix: "defdo_tenant"}]
      iex> Defdo.Tasks.Saas.MigratorChain.prefix_conflicts(ws, "my_app")
      [%{file: "a", up: 4, down: 4, prefix: "defdo_tenant"}]

  A dynamic prefix cannot be compared textually, so it is never reported.

      iex> ws = [%{file: "a", up: 4, down: 4, prefix: :dynamic}]
      iex> Defdo.Tasks.Saas.MigratorChain.prefix_conflicts(ws, "my_app")
      []
  """
  @spec prefix_conflicts([wrapper()], String.t()) :: [wrapper()]
  def prefix_conflicts(wrappers, expected) when is_binary(expected) do
    Enum.filter(wrappers, fn w ->
      is_binary(Map.get(w, :prefix)) and w.prefix != expected
    end)
  end

  @doc """
  The migration filename for a wrapper, using the same timestamp-plus-suffix
  scheme `defdo_tenant`'s installer uses so two generators run in the same
  second cannot collide.
  """
  @spec filename(pos_integer(), keyword()) :: String.t()
  def filename(version, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    suffix = Keyword.get_lazy(opts, :suffix, &unique_suffix/0)
    padded = String.pad_leading(to_string(version), 2, "0")

    "#{Calendar.strftime(now, "%Y%m%d%H%M%S")}#{suffix}_upgrade_defdo_tenant_migrator_v#{padded}.exs"
  end

  defp unique_suffix do
    System.unique_integer([:positive])
    |> rem(1000)
    |> Integer.to_string()
    |> String.pad_leading(3, "0")
  end

  @doc """
  The module name for a wrapper migration, e.g. `MyApp.Repo.Migrations.UpgradeDefdoTenantMigratorV04`.

      iex> Defdo.Tasks.Saas.MigratorChain.module_name(MyApp, 4)
      "MyApp.Repo.Migrations.UpgradeDefdoTenantMigratorV04"
  """
  @spec module_name(module(), pos_integer()) :: String.t()
  def module_name(app_module, version) do
    padded = String.pad_leading(to_string(version), 2, "0")
    "#{inspect(app_module)}.Repo.Migrations.UpgradeDefdoTenantMigratorV#{padded}"
  end

  @doc """
  Renders the wrapper migration source.

  `up` and `down` are pinned to the same explicit version — never floating, and
  never asymmetric. The comment explains the chain, because the next person to
  read this file will be looking at it precisely because something broke.
  """
  @spec render(module(), pos_integer(), String.t()) :: String.t()
  def render(app_module, version, prefix) do
    """
    defmodule #{module_name(app_module, version)} do
      @moduledoc \"\"\"
      Wrapper for `Defdo.Tenant.Migrator` schema version #{version}.

      Versions 1..3 arrive in most defdo apps indirectly: `defdo_vault`'s own
      version modules chain `Defdo.Tenant.Migrator.up/1` for v1, v2 and v3, so an
      app that runs the vault migrations never needed a tenant wrapper of its own.
      Nothing chains anything past v3, which is why `tenant_profiles` in an app
      without this file lacks `deleted_at` and every profile read against
      defdo_tenant 0.11+ fails with `column t0.deleted_at does not exist`.

      Pinned on both sides. `up/0` names the version explicitly so this migration
      applies the same schema in every environment regardless of which
      defdo_tenant is installed when it first runs. `down/0` names the same
      version because `Defdo.Migrations.down/1` rolls back down to *and
      including* the version given -- a lower number here would revert steps this
      migration never applied.

      Idempotent: the migrator records applied versions in
      `tenant_profiles_migrations` and skips what is already there.
      \"\"\"
      use Ecto.Migration

      @prefix "#{prefix}"

      def up do
        Defdo.Tenant.Migrator.up(version: #{version}, prefix: @prefix)
      end

      def down do
        Defdo.Tenant.Migrator.down(version: #{version}, prefix: @prefix)
      end
    end
    """
  end
end
