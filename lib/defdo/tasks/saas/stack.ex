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
  Compares an app's declared requirement against the version Hex says is
  *currently published*, in the direction that actually matters: can the
  declared requirement still admit today's release?

  This replaced a version of this check that compared the declared
  requirement against this module's own hardcoded `:requirement` field. That
  field drifts the moment the estate ships a release this package's source
  was not updated to know about, and when it drifts the comparison runs
  backwards: an app newer than the stale baseline gets told it is "pinned
  behind the stack" and offered a fix that would downgrade it. `current` must
  come from a live read (see `Defdo.Tasks.Saas.HexBaseline`), never from
  `fetch/1`.

  Returns:

    * `:ok` — the requirement admits the current release.
    * `{:behind, current}` — it does not, and the requirement's own floor is
      at or below the current release, so the app really is pinned behind a
      release it could otherwise take (a patch-level pin like `~> 0.13.0`
      once Hex ships `0.15.0`, for instance).
    * `{:ahead, floor}` — it does not, but the requirement's floor is *above*
      the current release. The app is not behind -- if anything Hex is, or
      the requirement names an unreleased version. Worth a note, never a
      warning.
    * `{:invalid, declared}` — the declared requirement does not parse.

      iex> Defdo.Tasks.Saas.Stack.compare_to_baseline("~> 0.13", "0.13.0")
      :ok

      iex> Defdo.Tasks.Saas.Stack.compare_to_baseline("~> 0.12", "0.13.0")
      :ok

      iex> Defdo.Tasks.Saas.Stack.compare_to_baseline("~> 0.13.0", "0.15.0")
      {:behind, "0.15.0"}

      iex> Defdo.Tasks.Saas.Stack.compare_to_baseline("~> 2.0", "0.13.0")
      {:ahead, "2.0.0"}

      iex> Defdo.Tasks.Saas.Stack.compare_to_baseline("not a version", "0.13.0")
      {:invalid, "not a version"}
  """
  @spec compare_to_baseline(String.t(), String.t() | Version.t()) ::
          :ok | {:behind, String.t()} | {:ahead, String.t()} | {:invalid, String.t()}
  def compare_to_baseline(declared, current) when is_binary(declared) do
    with {:ok, current_v} <- parse_version(current),
         {:ok, parsed} <- Version.parse_requirement(declared) do
      if Version.match?(current_v, parsed) do
        :ok
      else
        behind_or_ahead(declared, current_v)
      end
    else
      :error -> {:invalid, declared}
    end
  end

  defp parse_version(%Version{} = version), do: {:ok, version}
  defp parse_version(version) when is_binary(version), do: Version.parse(version)

  defp behind_or_ahead(declared, current_v) do
    case requirement_floor(declared) do
      {:ok, floor} ->
        if Version.compare(floor, current_v) == :gt do
          {:ahead, to_string(floor)}
        else
          {:behind, to_string(current_v)}
        end

      :error ->
        {:invalid, declared}
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
