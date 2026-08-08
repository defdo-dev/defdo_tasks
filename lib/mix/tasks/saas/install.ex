if match?({:module, _}, Code.ensure_compiled(Igniter.Mix.Task)) do
  defmodule Mix.Tasks.Defdo.Saas.Install do
    @shortdoc "Scaffolds a defdo SaaS app: stack, config, migrations, OAuth client shape"

    @moduledoc """
    Turns a Phoenix app into a defdo SaaS app.

        mix igniter.install defdo_tasks
        mix defdo.saas.install

    `phx.new` gives you a Phoenix app. This gives you a defdo one: the tenant
    stack wired, the tenant boundary configured to fail closed, the migration
    wrapper that nothing else carries, and the OAuth service client shape written
    as code instead of remembered.

    ## Why a generator and not documentation

    A model reading good documentation infers this stack correctly most of the
    time and fails on the unusual case. The three failures this task exists to
    prevent are all unusual cases, and all three have already happened:

      * The **tenant migrator chain**. Versions 1..3 arrive indirectly through
        `defdo_vault`'s migrations; nothing carries v4. Three apps adopted
        defdo_tenant 0.11+ and each broke identically at runtime with
        `column t0.deleted_at does not exist`.

      * The **OAuth service client shape**. To adopt the tenant its identity
        provider already knows, an app's client must both mint a token with no
        user behind it and read that token back — `client_credentials` *and*
        `introspect`, confidential. Of 12 applications registered in production,
        4 do not; one carries only `refresh_token` and `revoke`, so it can
        refresh tokens it has no way of obtaining.

      * **Requirement drift**. `~> 0.8.4` reads like a version requirement and
        behaves like a freeze: it cannot admit 0.9, and the app holding it sat
        four minor versions behind the rest of the estate.

    ## Two passes, on purpose

    The first run adds the dependency set and stops, because the tenant
    installer and the migrator version live inside packages that are not fetched
    yet. Run `mix deps.get`, then run this task again; the second pass composes
    `defdo_tenant.install`, writes the configuration, and generates the
    migration wrapper against the version of `Defdo.Tenant.Migrator` you
    actually have — never against a number hardcoded here.

    ## Options

      * `--repo` — the Ecto repo module, defaults to `<App>.Repo`
      * `--prefix` — the schema prefix, defaults to the OTP app name
      * `--enforcement` — `strict` (default), `test_enforce`, `warn` or `observe`
      * `--with-payments` / `--no-with-payments` — defdo_payments for tenant
        subscriptions, on by default
      * `--with-provision` — add defdo_tenant_provision (not published yet;
        off by default)
      * `--no-oauth-client` — skip generating the service client module
    """

    use Igniter.Mix.Task

    alias Defdo.Tasks.Saas.OAuthClient
    alias Defdo.Tasks.Saas.Stack
    alias Igniter.Project.Application, as: IgniterApp
    alias Igniter.Project.Config
    alias Igniter.Project.Deps
    alias Igniter.Project.Module, as: IgniterModule

    @enforcement_modes ~w(strict test_enforce warn observe)

    @impl Igniter.Mix.Task
    def supports_umbrella?, do: false

    @impl Igniter.Mix.Task
    def installer?, do: true

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :defdo,
        schema: [
          repo: :string,
          prefix: :string,
          enforcement: :string,
          with_payments: :boolean,
          with_provision: :boolean,
          oauth_client: :boolean
        ],
        defaults: [with_payments: true, with_provision: false, oauth_client: true],
        composes: ["defdo_tenant.install", "defdo.saas.migrations"],
        dep_opts: [organization: :defdo],
        example: "mix igniter.install defdo_tasks"
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      options = igniter.args.options
      app_name = IgniterApp.app_name(igniter)
      app_module = IgniterModule.module_name_prefix(igniter)
      repo_module = repo_module(options[:repo], app_module)
      prefix = options[:prefix] || to_string(app_name)
      # Validated before anything is written, not at the point of use: the
      # second pass is where it gets consumed, and a typo should not survive
      # until then.
      enforcement = enforcement(options)

      igniter
      |> add_stack_deps(options)
      |> then(fn igniter ->
        if tenant_available?() do
          igniter
          |> configure_tenant(repo_module, enforcement)
          |> configure_vault(repo_module)
          |> compose_tenant_installer(repo_module)
          |> Igniter.compose_task("defdo.saas.migrations", ["--prefix", prefix])
          |> maybe_generate_oauth_client(options, app_module, app_name)
          |> next_steps(options, app_name, prefix)
        else
          first_pass_notice(igniter)
        end
      end)
    end

    defp repo_module(nil, app_module), do: Module.concat(app_module, Repo)
    defp repo_module(repo, _app_module), do: Module.concat([repo])

    defp enforcement(options) do
      case options[:enforcement] do
        nil ->
          :strict

        mode when mode in @enforcement_modes ->
          String.to_atom(mode)

        other ->
          Mix.raise(
            "unknown --enforcement #{inspect(other)}, expected one of #{Enum.join(@enforcement_modes, ", ")}"
          )
      end
    end

    # defdo_tenant is the package the rest of the pass reads from -- the migrator
    # version, the installer task. If it is not compiled yet, everything after
    # the dependency set would be guesswork.
    defp tenant_available?, do: Code.ensure_loaded?(Defdo.Tenant.Migrator)

    # -- dependencies --------------------------------------------------------

    defp add_stack_deps(igniter, options) do
      tiers = [:core] ++ if(options[:with_payments] != false, do: [:recommended], else: [])

      selected =
        Stack.select(tiers) ++
          if options[:with_provision], do: [Stack.fetch(:defdo_tenant_provision)], else: []

      Enum.reduce(selected, igniter, fn dep, acc ->
        # `on_exists: :skip` so re-running the task never rewrites a requirement
        # the app has deliberately widened or pinned.
        Deps.add_dep(acc, Stack.to_tuple(dep), on_exists: :skip, append?: true)
      end)
    end

    # -- configuration -------------------------------------------------------

    defp configure_tenant(igniter, repo_module, enforcement) do
      igniter
      |> Config.configure("config.exs", :defdo_tenant, [:repo], repo_module)
      |> Config.configure("config.exs", :defdo_tenant, [:enforcement], enforcement)
      |> Config.configure("config.exs", :defdo_tenant, [:tenant_key], :tenant_id)
      |> then(fn igniter ->
        # `:strict` raises at runtime on an unscoped query, which is what you
        # want in production and not what you want the first time a test forgets
        # to establish context. `:test_enforce` raises only in `:test`.
        Config.configure(igniter, "test.exs", :defdo_tenant, [:enforcement], :test_enforce)
      end)
      |> Igniter.add_notice("""
      Tenant boundary configured with enforcement: #{inspect(enforcement)}.

      `:strict` fails closed: a query against a tenant-owned table with no tenant in the
      process context raises rather than quietly returning another tenant's rows. Most apps
      in this estate never set this key at all and run at the library default, which only
      observes.
      """)
    end

    defp configure_vault(igniter, repo_module) do
      igniter
      |> Config.configure("config.exs", :defdo_vault, [:repo], repo_module)
      |> Igniter.add_notice("""
      defdo_vault runs on your repo. Set its encryption key from the environment in
      `config/runtime.exs` -- never in `config/config.exs`, which is committed:

          config :defdo_vault, :encryption_key, System.fetch_env!("DEFDO_VAULT_KEY")

      Two apps in this estate have a real base64 key literal in a committed config file.
      """)
    end

    defp compose_tenant_installer(igniter, repo_module) do
      if Mix.Task.get("defdo_tenant.install") do
        Igniter.compose_task(igniter, "defdo_tenant.install", ["--repo", inspect(repo_module)])
      else
        Igniter.add_warning(igniter, """
        `mix defdo_tenant.install` is not available, so the repo, SkipTables module, tenant
        plug and test fixtures were not generated. That task ships with defdo_tenant and needs
        Igniter present when defdo_tenant compiles.

        Run it yourself once deps are in place:

            mix defdo_tenant.install --repo #{inspect(repo_module)}
        """)
      end
    end

    # -- OAuth service client ------------------------------------------------

    defp maybe_generate_oauth_client(igniter, options, app_module, app_name) do
      if options[:oauth_client] == false do
        igniter
      else
        module = Module.concat([app_module, OAuth, ServiceClient])

        igniter
        |> IgniterModule.create_module(module, oauth_client_body(app_name))
        |> Igniter.add_notice("""
        Generated #{inspect(module)}.

        Its `attrs/1` is the shape to register, and `validate/1` is the assertion to run
        against what is actually registered. Registering by hand is where the shape gets
        lost: 4 of 12 applications in production cannot introspect, and one of those can
        only refresh tokens it has no way of obtaining.
        """)
      end
    end

    defp oauth_client_body(app_name) do
      spec = OAuthClient.spec(:instance_service)
      grants = inspect(spec.required_grants)
      auth_methods = inspect(spec.auth_methods)

      """
      @moduledoc \"\"\"
      The OAuth service client this instance needs to adopt its own tenant.

      Adoption works by minting a token from this instance's own credentials and
      reading the tenant back out of it. That is two capabilities, not one:
      obtaining a token with no user behind it (`client_credentials`) and reading
      it back (`introspect`). Both are refused unless the client presents a
      secret, so the client must be confidential.

      Keep this module as the single description of that shape. `attrs/0` is what
      to register; `validate/1` is what to assert against what is registered.
      \"\"\"

      @grants #{grants}
      @auth_methods #{auth_methods}
      @grants_that_obtain_a_token ~w(client_credentials authorization_code password implicit)

      @doc \"\"\"
      The attrs to hand to `Defdo.Auth.Tenant.create_app/1`.
      \"\"\"
      def attrs(opts \\\\ []) do
        name = Keyword.get(opts, :name, "#{app_name}")

        %{
          name: name,
          type: "m2m",
          auth_method: "basic",
          active: true,
          supported_grant_types: @grants,
          client: %{
            name: name,
            confidential: true,
            redirect_uris: [],
            supported_grant_types: @grants,
            token_endpoint_auth_methods: @auth_methods
          },
          scopes: Keyword.get(opts, :scopes, []),
          skip_consent: true
        }
        |> Map.merge(Map.new(Keyword.take(opts, [:tenant_id, :connection_id])))
      end

      @doc \"\"\"
      Checks a registered client against the shape above.

      Returns `:ok` or `{:error, reasons}`. Call it at boot, or from a release
      task, so a client registered by hand cannot quietly be the wrong shape.
      \"\"\"
      def validate(client) when is_map(client) do
        grants =
          client
          |> Map.get(:supported_grant_types, Map.get(client, "supported_grant_types", []))
          |> List.wrap()
          |> Enum.map(&to_string/1)

        confidential? = Map.get(client, :confidential, Map.get(client, "confidential"))

        reasons =
          []
          |> then(fn acc ->
            case @grants -- grants do
              [] -> acc
              missing -> ["missing required grant(s): " <> Enum.join(missing, ", ") | acc]
            end
          end)
          |> then(fn acc ->
            if "refresh_token" in grants and
                 not Enum.any?(grants, &(&1 in @grants_that_obtain_a_token)) do
              ["carries refresh_token but no grant that obtains one" | acc]
            else
              acc
            end
          end)
          |> then(fn acc ->
            if confidential? == true,
              do: acc,
              else: ["client is not confidential; client_credentials and introspect need a secret" | acc]
          end)

        case reasons do
          [] -> :ok
          reasons -> {:error, Enum.reverse(reasons)}
        end
      end
      """
    end

    # -- notices -------------------------------------------------------------

    defp first_pass_notice(igniter) do
      Igniter.add_notice(igniter, """
      Added the defdo SaaS stack to mix.exs. This was pass one of two.

      Run:

          mix deps.get
          mix defdo.saas.install

      The second pass composes `defdo_tenant.install`, writes the tenant and vault
      configuration, and generates the migrator wrapper. It is deliberately deferred:
      the wrapper's version is read from the `Defdo.Tenant.Migrator` you actually have
      rather than from a constant in defdo_tasks, and that package is not fetched yet.
      """)
    end

    defp next_steps(igniter, options, app_name, prefix) do
      payments =
        if options[:with_payments] == false do
          "  * defdo_payments was skipped. Add it when tenants start paying: " <>
            Stack.to_source(Stack.fetch(:defdo_payments))
        else
          "  * defdo_payments is in. It is an API client, not a tenant-aware package -- " <>
            "the subscription-to-entitlement mapping is yours to write."
        end

      Igniter.add_notice(igniter, """
      Next steps

        * `mix ecto.create && mix ecto.migrate` -- the schema prefix is "#{prefix}".

        * Register the OAuth service client with the shape #{inspect(app_name)} needs
          (#{OAuthClient.describe(:instance_service)}):

      #{OAuthClient.registration_command(:instance_service, name: to_string(app_name)) |> String.trim() |> indent(6)}

        * Set `DEFDO_VAULT_KEY` in the environment before booting.

      #{payments}

        * `mix defdo.saas.doctor` audits all of this later, and is worth a CI step --
          it is what catches the migrator chain falling behind on the next release.
      """)
    end

    defp indent(text, spaces) do
      pad = String.duplicate(" ", spaces)

      text
      |> String.split("\n")
      |> Enum.map_join("\n", &(pad <> &1))
    end
  end
else
  defmodule Mix.Tasks.Defdo.Saas.Install do
    @shortdoc "Scaffolds a defdo SaaS app (requires Igniter)"
    @moduledoc """
    Requires Igniter. Add it and re-run:

        {:igniter, "~> 0.6 or ~> 0.7 or ~> 0.8", only: [:dev, :test]}
    """

    use Mix.Task

    @impl Mix.Task
    def run(_argv) do
      Mix.shell().error("""
      mix defdo.saas.install requires Igniter.

      Add `{:igniter, "~> 0.6 or ~> 0.7 or ~> 0.8", only: [:dev, :test]}` to your deps,
      run `mix deps.get`, and try again -- or install this package the Igniter way:

          mix igniter.install defdo_tasks
      """)

      exit({:shutdown, 1})
    end
  end
end
