# Defdo.Tasks

Mix tasks that scaffold and audit defdo SaaS apps.

```elixir
def deps do
  [
    {:defdo_tasks, "~> 0.2", organization: :defdo, runtime: false}
  ]
end
```

## Creating a defdo SaaS app

```
mix igniter.install defdo_tasks
mix defdo.saas.install
```

`phx.new` gives you a Phoenix app. This gives you a defdo one: `defdo_tenant`
plus the `defdo_tenant_*` family, `defdo_vault`, `defdo_payments` for tenant
subscriptions, the tenant boundary configured to fail closed, the migration
wrapper that nothing else carries, and the OAuth service client shape written
as code instead of remembered.

It runs in two passes on purpose. The first adds the dependency set and stops;
the second — after `mix deps.get` — composes `defdo_tenant.install`, writes the
configuration, and generates the migration wrapper against the version of
`Defdo.Tenant.Migrator` you actually have rather than a number hardcoded here.

### Why a generator and not documentation

A model reading good documentation infers this stack correctly most of the time
and fails on the unusual case. The failures below are all unusual cases, and all
of them have already happened in production.

**The tenant migrator chain.** `Defdo.Tenant.Migrator` versions 1–3 reach most
apps *indirectly*: `defdo_vault`'s own version modules (`v2.ex`, `v4.ex`,
`v7.ex`) chain them, so an app that runs the vault migrations gets tenant tables
without ever writing a wrapper. Nothing chains v4. Three apps adopted
`defdo_tenant` 0.11+ and each broke identically at runtime with
`column t0.deleted_at does not exist`, and each was repaired by a hand-written
wrapper — three wrappers, no two the same, one of which rolls back a version it
never applied.

**The OAuth service client shape.** To adopt the tenant its identity provider
already knows, an app must both mint a token with no user behind it and read
that token back: `client_credentials` *and* `introspect`, confidential. Of 12
applications registered in production, 4 cannot introspect; one carries only
`refresh_token` and `revoke`, so it can refresh tokens it has no way of
obtaining.

**Requirement drift.** `~> 0.8.4` reads like a version requirement and behaves
like a freeze — it cannot admit 0.9.0 at all. (`~> 0.10` is *not* a freeze: it
means `>= 0.10.0 and < 1.0.0`, so most of this estate can already resolve
`defdo_tenant` 0.12, which is why so many apps are exposed to the v4 gap rather
than protected from it.)

## Auditing an app that already exists

```
mix defdo.saas.doctor
mix defdo.saas.doctor --strict
```

Needs no Igniter, writes nothing, and exits 1 when it finds an error, so it can
gate a pipeline. It reports:

- a missing, floating, or behind tenant migrator wrapper — and a wrapper whose
  `down` reverts more than its `up` applied
- wrappers that disagree about which Postgres schema the tenant tables live in
  (they do not conflict at migration time; they build two copies and let
  `search_path` decide)
- stack dependencies that are absent, or pinned so tightly they cannot admit the
  version the stack targets
- `defdo_compiled_config.exs` returning the wrong type for migration keys
- an OAuth client shape, when one is passed on the command line:

```
mix defdo.saas.doctor \
  --oauth-grants refresh_token,revoke --oauth-confidential
```

## Fixing only the migrator chain

```
mix defdo.saas.migrations
```

For an app that is otherwise fine and just needs the wrapper. Pinned on both
sides to an explicit version, idempotent, and safe to re-run.

## The other tasks

| Task | What it does |
| --- | --- |
| `mix defdo.repo.pg.new_schema` | Creates Postgres schemas via `psql` |
| `mix defdo.repo.pg.create_extension` | Creates Postgres extensions via `psql` |
| `mix defdo.repo.compiled_config` | Generates the repo flavour config; `--check` reports drift |

## Two OAuth roles, not one

`Defdo.Tasks.Saas.OAuthClient` validates against a role, because this estate has
two service-client shapes that look like one problem:

- `:instance_service` — the app adopting its own tenant. Needs
  `client_credentials` **and** `introspect`, confidential.
- `:platform_introspection` — the shared-host client that resolves a token to a
  tenant. `defdo_auth` requires `introspect` and *nothing else*; adding
  `client_credentials` here actively disqualifies it.

One client cannot satisfy both. Asking for the wrong role is a thing this
module makes loud.

## Verifying the generator

The Igniter tasks are tested with `Igniter.Test` against in-memory projects. The
second pass — which needs the real `defdo_tenant` package to read a migrator
version from — is verified by running both passes against a scratch Phoenix
project and checking that the full dependency set resolves from Hex, that the
generated wrapper names the version the installed migrator actually has, and
that the generated OAuth module validates its own attrs.
