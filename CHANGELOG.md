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
- `Mix.Tasks.Defdo.Repo.Pg.NewSchema.otp_app/0` and
  `Mix.Tasks.Defdo.Repo.Pg.CreateExtension.otp_app/0` were removed in favour of
  `Defdo.Tasks.Repo.Psql.current_otp_app/0`. They were helpers on Mix task
  modules and are not expected to have callers.

# 0.1.1

- Add `defdo.repo.pg.create_extension` task.
- Fix `defdo.repo.compiled_config` template typo for migration keys.

# 0.1.0

- Add `defdo.repo.pg.new_schema` and `defdo.repo.compiled_config` tasks.
