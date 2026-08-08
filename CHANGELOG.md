# 0.3.0

## Added

- `Defdo.Tasks.Repo.Extensions` — a declarative Postgres-extension precheck
  (#9). `ensure!/3` verifies required extensions exist and, on a miss, raises a
  `MissingExtensionError` naming every missing extension plus the exact
  remediation command (`mix defdo.repo.pg.create_extension --name <ext>
  --repo <Repo> --otp-app <app>`). Opt-in `create_extensions: true` tries
  `CREATE EXTENSION IF NOT EXISTS` first and falls back to the actionable error
  on insufficient privilege. Raises a plain exception (never `Mix.raise`), so it
  is safe inside a release `Release.migrate/0`. Names are validated and
  double-quoted in DDL; the existing `defdo.repo.pg.create_extension` task now
  reuses that validation.
- `mix defdo.ssl.setup` — generates local dev HTTPS certs via defdo's custom
  mkcert build for `<project_name>` + `localhost`, writing
  `priv/ssl/<project_name>{,_key}.pem`, and injects an idempotent, marker-
  delimited `https:` block into `config/dev.exs` and `config/runtime.exs` (#1).
  The mkcert download URL/version are overridable (`--url`/`--base-url`/
  `--version`, or config) with a documented, unverified default.
- `defdo_saas.status` — a fourth read-only MCP tool answering "where are we"
  from live estate state: open PRs (via `gh`, degrading gracefully), dependency
  drift with the two- vs three-segment `~>` cap distinction, migrator wrapper
  chain (including indirect wrappers), blocked-by from published requirements,
  and local-vs-origin divergence (#8).

## Changed

- `defdo_saas.migrator_chain` now resolves the migrator target from the
  dependency the app actually has instead of assuming it (#7). The payload
  reports `target_version_source` (`deps`/`lock`/`assumed`),
  `target_version_confidence` (`resolved`/`from_lock`/`assumed`), and the
  resolved dependency/version. When the source is `assumed`, `status` no longer
  claims `current` against a guessed number — it reports `unknown` with a
  reason.

# 0.2.0

First release since 2024-08-10. Adopts Igniter and turns this package into the
way a defdo SaaS app gets generated.

## Added

- `mix defdo.saas.install` — an Igniter installer that scaffolds a defdo SaaS
  app: the dependency set, the tenant boundary configuration, the migration
  wrapper, the OAuth service client module, and a composed
  `mix defdo_tenant.install`. Runs in two passes so the migrator version is read
  from the installed package rather than hardcoded here.
- `mix defdo.saas.migrations` — an Igniter task that writes the
  `Defdo.Tenant.Migrator` wrapper an app is missing. Pinned on both sides to an
  explicit version, idempotent, and safe to re-run. Reads Igniter's staged files
  as well as disk, so composing it after another installer reconciles rather
  than duplicating.
- `mix defdo.saas.doctor` — a plain Mix task (no Igniter required) that audits an
  existing app: migrator chain coverage, floating and asymmetric wrappers,
  wrappers that disagree about the schema prefix, stack dependency drift,
  `defdo_compiled_config.exs` key-type drift, and OAuth client shape. Exits 1 on
  errors so it can gate CI.
- `Defdo.Tasks.Saas.Stack` — the defdo SaaS dependency set as data, with tiers
  and verified version requirements.
- `Defdo.Tasks.Saas.MigratorChain` — migrator wrapper detection and rendering.
  The target version is probed from the migrator's version modules rather than
  hardcoded, so this package does not go stale the way the thing it fixes did.
- `Defdo.Tasks.Saas.OAuthClient` — the service client shape, validated against a
  role. Names the `refresh_token`-without-`client_credentials` failure
  explicitly, and encodes `:platform_introspection` as a separate role because
  `defdo_auth` requires `introspect` and nothing else for that job.
- `Defdo.Tasks.Saas.Audit` — the doctor's checks as pure functions, callable from
  an app's own test suite.
- `mix defdo.repo.compiled_config --check` — reports flavour-file drift without
  writing. Two apps in the estate return `[type: :timestamptz]` for migration
  primary and foreign keys where the generator emits `[type: :binary_id]`.

## Fixed

- `mix defdo.repo.pg.new_schema` dropped empty entries from its schema list, so
  `--schema "a,"` no longer emits `CREATE SCHEMA IF NOT EXISTS ;`.
- `mix defdo.repo.pg.create_extension` now honours the configured port. `--port`
  support was added to `new_schema` and never to this task, so it always
  connected on 5432.
- Both `pg` tasks raise with the configuration you are missing when the repo has
  none. They used to interpolate `nil` into the connection settings and shell out
  to `psql -U  -h  -d `, producing a psql error rather than an actionable one.
- Both `pg` tasks raise a clear error for an unknown `--repo` instead of a bare
  `ArgumentError`.
- `mix defdo.repo.compiled_config` no longer silently overwrites an existing
  file. Apps have deliberately extended theirs; `--force` still overwrites.

## Changed

- The generated repo flavour now ships `migration_default_prefix/0` and a
  `Code.ensure_loaded?` guard. Both were added by hand in several apps, which is
  why five variants of this file exist.
- `mix.exs` no longer declares an OTP application module. This package is Mix
  tasks and pure helpers; consumers depend on it with `runtime: false`, and the
  supervisor owned nothing.
- Minimum Elixir is now 1.15 (Igniter's floor).
- The `otp_app/0` helpers on `Mix.Tasks.Defdo.Repo.Pg.NewSchema` and
  `Mix.Tasks.Defdo.Repo.Pg.CreateExtension` were removed in favour of
  `Defdo.Tasks.Repo.Psql.current_otp_app/0`. They were helpers on Mix task
  modules and are not expected to have callers.

# 0.1.1

- Add `defdo.repo.pg.create_extension` task.
- Fix `defdo.repo.compiled_config` template typo for migration keys.

# 0.1.0

- Add `defdo.repo.pg.new_schema` and `defdo.repo.compiled_config` tasks.
