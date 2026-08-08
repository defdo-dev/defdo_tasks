defmodule Defdo.Tasks.Saas.Stack do
  @moduledoc """
  The dependency set of a defdo SaaS app, as data.

  This is the answer to "what does `create a defdo SaaS app` mean", written once
  so the generator (`mix defdo.saas.install`) and the auditor
  (`mix defdo.saas.doctor`) cannot disagree about it. A model reading docs infers
  this set correctly most of the time; a module returning it is correct every
  time.

  ## Tiers

  Each entry carries a `:tier`, and the tier is the opinion:

    * `:core` — installed unless explicitly skipped. Without these the app is not
      a defdo SaaS app.
    * `:recommended` — installed by default, but an app can legitimately ship
      without them.
    * `:optional` — never installed unless asked for by name.

  ## Version requirements

  Requirements are deliberately written at the minor level (`~> 0.12`, which in
  Elixir means `>= 0.12.0 and < 1.0.0` for a leading zero) rather than pinned to
  a patch. A patch-level pin such as `~> 0.8.4` is what froze `defdo_shop` four
  minor versions behind the rest of the estate.
  """

  @typedoc "How strongly the stack recommends a dependency."
  @type tier :: :core | :recommended | :optional

  @typedoc """
  One dependency of the defdo SaaS stack.

    * `:name` — the OTP application name
    * `:requirement` — the version requirement to write into `mix.exs`
    * `:tier` — see `t:tier/0`
    * `:hex` — `true` when the package lives in the private `defdo` Hex
      organization and the dep entry needs `organization: :defdo`
    * `:published?` — `false` for packages that exist in the estate but have
      never resolved from Hex; the generator must not emit these by default
    * `:why` — the one-line reason, surfaced verbatim in generated comments and
      in `mix defdo.saas.doctor` output
  """
  @type dep :: %{
          name: atom(),
          requirement: String.t(),
          tier: tier(),
          hex: boolean(),
          published?: boolean(),
          why: String.t()
        }

  # Verified against the estate on the 0.2.0 branch: every requirement below
  # admits the version currently published to the `defdo` Hex organization, and
  # the set resolves together (defdo_vault requires defdo_tenant "~> 0.10" and
  # defdo_tenant_boundary requires "~> 0.10.3 or ~> 0.11" -- both admit 0.12.x,
  # because `~> 0.10` means `< 1.0.0`, not `< 0.11.0`).
  @deps [
    %{
      name: :defdo_tenant,
      requirement: "~> 0.12",
      tier: :core,
      hex: true,
      published?: true,
      why: "Tenant profiles, column isolation and the process-local tenant context."
    },
    %{
      name: :defdo_tenant_plug,
      requirement: "~> 0.2",
      tier: :core,
      hex: true,
      published?: true,
      why:
        "Resolves the tenant at the HTTP/socket edge. Depends on plug only, not on defdo_tenant."
    },
    %{
      name: :defdo_tenant_boundary,
      requirement: "~> 0.2",
      tier: :core,
      hex: true,
      published?: true,
      why:
        "Carries the tenant across Task, Oban, GenServer, PubSub, webhook, cache and storage hops."
    },
    %{
      name: :defdo_vault,
      requirement: "~> 0.10",
      tier: :core,
      hex: true,
      published?: true,
      why:
        "Encrypted secrets and parameters. Also owns the migration chain that seeds tenant tables."
    },
    %{
      name: :defdo_payments,
      requirement: "~> 0.3",
      tier: :recommended,
      hex: true,
      published?: true,
      why: "Tenant subscriptions and billing. Recommended for any app that charges per tenant."
    },
    %{
      name: :defdo_tenant_provision,
      requirement: "~> 0.1",
      tier: :optional,
      hex: true,
      published?: false,
      why:
        "One provisioning path: idempotency envelope, transactional core, best-effort after commit."
    }
  ]

  @default_tiers [:core, :recommended]

  @doc """
  Every dependency the stack knows about, in install order.

      iex> Defdo.Tasks.Saas.Stack.all() |> Enum.map(& &1.name) |> Enum.take(2)
      [:defdo_tenant, :defdo_tenant_plug]
  """
  @spec all() :: [dep()]
  def all, do: @deps

  @doc """
  The dependencies in the given tiers, defaulting to `#{inspect(@default_tiers)}`.

  Unpublished packages are excluded unless their tier was asked for by name, so
  a plain `select/0` never emits a dependency that cannot resolve from Hex.

      iex> Defdo.Tasks.Saas.Stack.select() |> Enum.map(& &1.name)
      [:defdo_tenant, :defdo_tenant_plug, :defdo_tenant_boundary, :defdo_vault, :defdo_payments]

      iex> Defdo.Tasks.Saas.Stack.select([:core]) |> Enum.map(& &1.name)
      [:defdo_tenant, :defdo_tenant_plug, :defdo_tenant_boundary, :defdo_vault]
  """
  @spec select([tier()]) :: [dep()]
  def select(tiers \\ @default_tiers) when is_list(tiers) do
    Enum.filter(@deps, fn dep ->
      dep.tier in tiers and (dep.published? or dep.tier == :optional)
    end)
  end

  @doc """
  Looks a dependency up by name.

      iex> Defdo.Tasks.Saas.Stack.fetch(:defdo_vault).tier
      :core

      iex> Defdo.Tasks.Saas.Stack.fetch(:phoenix)
      nil
  """
  @spec fetch(atom()) :: dep() | nil
  def fetch(name) when is_atom(name), do: Enum.find(@deps, &(&1.name == name))

  @doc """
  Renders a dependency as the tuple to hand to `Igniter.Project.Deps.add_dep/3`.

      iex> Defdo.Tasks.Saas.Stack.to_tuple(Defdo.Tasks.Saas.Stack.fetch(:defdo_tenant))
      {:defdo_tenant, "~> 0.12", [organization: :defdo]}
  """
  @spec to_tuple(dep()) :: {atom(), String.t(), keyword()}
  def to_tuple(%{name: name, requirement: requirement, hex: hex?}) do
    opts = if hex?, do: [organization: :defdo], else: []
    {name, requirement, opts}
  end

  @doc """
  Renders a dependency as the literal line a human would write in `mix.exs`.

      iex> Defdo.Tasks.Saas.Stack.to_source(Defdo.Tasks.Saas.Stack.fetch(:defdo_vault))
      ~s({:defdo_vault, "~> 0.10", organization: :defdo})
  """
  @spec to_source(dep()) :: String.t()
  def to_source(%{name: name, requirement: requirement, hex: hex?}) do
    suffix = if hex?, do: ", organization: :defdo", else: ""
    "{:#{name}, \"#{requirement}\"#{suffix}}"
  end

  @doc """
  Checks an app's declared requirement for a stack dependency against the
  version the stack expects.

  Returns `:ok`, or `{:stale, expected}` when the declared requirement cannot
  admit any version the stack targets. This is what catches a `~> 0.8.4` that
  silently holds an app four minor versions back.

      iex> Defdo.Tasks.Saas.Stack.check_requirement(:defdo_tenant, "~> 0.12")
      :ok

      iex> Defdo.Tasks.Saas.Stack.check_requirement(:defdo_tenant, "~> 0.10")
      :ok

      iex> Defdo.Tasks.Saas.Stack.check_requirement(:defdo_tenant, "~> 0.8.4")
      {:stale, "~> 0.12"}

      iex> Defdo.Tasks.Saas.Stack.check_requirement(:not_a_defdo_package, "~> 1.0")
      :ok
  """
  @spec check_requirement(atom(), String.t()) ::
          :ok | {:stale, String.t()} | {:invalid, String.t()}
  def check_requirement(name, declared) when is_atom(name) and is_binary(declared) do
    case fetch(name) do
      nil -> :ok
      dep -> compare_requirement(dep, declared)
    end
  end

  defp compare_requirement(dep, declared) do
    # The floor of the stack's own requirement: "~> 0.12" -> "0.12.0". If the
    # app's requirement cannot admit that version, the app is pinned behind the
    # stack no matter how the requirement is spelled.
    with {:ok, floor} <- requirement_floor(dep.requirement),
         {:ok, parsed} <- Version.parse_requirement(declared) do
      if Version.match?(floor, parsed), do: :ok, else: {:stale, dep.requirement}
    else
      :error -> {:invalid, declared}
    end
  end

  defp requirement_floor(requirement) do
    requirement
    |> String.replace(~r/^[~><=\s]+/, "")
    |> String.split(".")
    |> case do
      [major, minor] -> Version.parse("#{major}.#{minor}.0")
      [major, minor, patch | _] -> Version.parse("#{major}.#{minor}.#{patch}")
      _other -> :error
    end
  end
end
