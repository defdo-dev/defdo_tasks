defmodule Defdo.Tasks.Saas.OAuthClient do
  @moduledoc """
  The shape a defdo SaaS app's OAuth client must have, and a check for it.

  ## Why this module exists

  For an instance to adopt the tenant its identity provider already knows, it
  mints a token from its own credentials and reads the tenant back out of it.
  That is two capabilities, not one: obtaining a token with no user behind it
  (`client_credentials`), and reading it back (`introspect`). Both are refused
  unless the client presents a secret, so the client must be confidential.

  Registering that by hand is where the shape gets lost. Of 12 applications
  registered in one production estate, 4 could not introspect at all — one
  carried only `refresh_token` and `revoke`, which lets it refresh tokens it has
  no way of ever obtaining. `validate/2` names that exact failure.

  ## Two roles, not one

  The estate contains two service-client shapes that look like one problem and
  are not, so this module encodes both rather than picking a winner:

    * `:instance_service` — the app adopting its own tenant. Needs
      `client_credentials` **and** `introspect`, confidential.

    * `:platform_introspection` — the shared-host client that resolves a token
      to a tenant across tenants. `defdo_auth` requires this one to carry
      `introspect` and *nothing else*: `Defdo.Auth.OAuth.PlatformIntrospection`
      classifies a client as a platform client only when every grant it has is
      `introspect`, so adding `client_credentials` here actively disqualifies it.

  Asking for the wrong role is the mistake this module is built to make loud.
  A client cannot satisfy both roles at once, and one registration cannot serve
  both purposes.
  """

  @typedoc "Which job the client is registered to do."
  @type role :: :instance_service | :platform_introspection

  @typedoc "A finding from `validate/2`. `:severity` is `:error` or `:warning`."
  @type finding :: %{severity: :error | :warning, message: String.t()}

  @grants_that_obtain_a_token ~w(client_credentials authorization_code password implicit)

  @specs %{
    instance_service: %{
      required_grants: ~w(client_credentials introspect),
      exact_grants?: false,
      confidential: true,
      auth_methods: ~w(client_secret_basic client_secret_post),
      app_type: "m2m",
      purpose: "adopt the tenant the identity provider already knows"
    },
    platform_introspection: %{
      required_grants: ~w(introspect),
      exact_grants?: true,
      confidential: true,
      auth_methods: ~w(client_secret_basic client_secret_post),
      app_type: "m2m",
      purpose: "resolve a token to a tenant on a shared host"
    }
  }

  @doc "The roles this module knows how to validate."
  @spec roles() :: [role()]
  def roles, do: Map.keys(@specs)

  @doc """
  The required shape for a role.

      iex> Defdo.Tasks.Saas.OAuthClient.spec(:instance_service).required_grants
      ["client_credentials", "introspect"]

      iex> Defdo.Tasks.Saas.OAuthClient.spec(:platform_introspection).exact_grants?
      true
  """
  @spec spec(role()) :: map()
  def spec(role) when is_map_key(@specs, role), do: Map.fetch!(@specs, role)

  @doc """
  Validates a client's actual shape against a role.

  `client` accepts the field names the estate actually uses:
  `:supported_grant_types` (or `:grants`), `:confidential`, and
  `:token_endpoint_auth_methods` (or `:auth_method`). String keys work too.

      iex> Defdo.Tasks.Saas.OAuthClient.validate(%{
      ...>   supported_grant_types: ["client_credentials", "introspect"],
      ...>   confidential: true
      ...> })
      :ok

  The failure from the issue — a client that can refresh but never obtain:

      iex> {:error, findings} =
      ...>   Defdo.Tasks.Saas.OAuthClient.validate(%{
      ...>     supported_grant_types: ["refresh_token", "revoke"],
      ...>     confidential: true
      ...>   })
      iex> Enum.any?(findings, &(&1.message =~ "can never obtain"))
      true

  And the `m2m` preset, which ships `client_credentials` with no `introspect`:

      iex> {:error, findings} =
      ...>   Defdo.Tasks.Saas.OAuthClient.validate(%{
      ...>     supported_grant_types: ["client_credentials"],
      ...>     confidential: true
      ...>   })
      iex> Enum.map(findings, & &1.severity)
      [:error]
  """
  @spec validate(map(), role()) :: :ok | {:error, [finding()]}
  def validate(client, role \\ :instance_service) when is_map(client) do
    spec = spec(role)
    grants = grants(client)

    findings =
      []
      |> check_missing_grants(spec, grants)
      |> check_extra_grants(spec, grants)
      |> check_refresh_without_obtain(grants)
      |> check_confidential(spec, client)
      |> check_auth_methods(spec, client)
      |> Enum.reverse()

    if Enum.any?(findings, &(&1.severity == :error)), do: {:error, findings}, else: :ok
  end

  defp check_missing_grants(findings, spec, grants) do
    case spec.required_grants -- grants do
      [] ->
        findings

      missing ->
        [
          error(
            "missing required grant#{plural(missing)} #{inspect(missing)} " <>
              "-- the client cannot #{spec.purpose} without #{join(missing)}"
          )
          | findings
        ]
    end
  end

  defp check_extra_grants(findings, %{exact_grants?: true} = spec, grants) do
    case grants -- spec.required_grants do
      [] ->
        findings

      extra ->
        [
          error(
            "grant#{plural(extra)} #{inspect(extra)} disqualify this client " <>
              "-- a platform introspection client must carry `introspect` and nothing else"
          )
          | findings
        ]
    end
  end

  defp check_extra_grants(findings, _spec, _grants), do: findings

  defp check_refresh_without_obtain(findings, grants) do
    if "refresh_token" in grants and not Enum.any?(grants, &(&1 in @grants_that_obtain_a_token)) do
      [
        error(
          "carries `refresh_token` but no grant that obtains one " <>
            "(#{join(@grants_that_obtain_a_token)}) -- it can refresh tokens it can never obtain"
        )
        | findings
      ]
    else
      findings
    end
  end

  defp check_confidential(findings, %{confidential: true}, client) do
    case get(client, [:confidential]) do
      true ->
        findings

      nil ->
        [
          warning("`confidential` not reported -- cannot verify the client is confidential")
          | findings
        ]

      _false ->
        [
          error(
            "client is public -- `client_credentials` and `introspect` are both refused " <>
              "unless the client presents a secret"
          )
          | findings
        ]
    end
  end

  defp check_confidential(findings, _spec, _client), do: findings

  defp check_auth_methods(findings, spec, client) do
    case auth_methods(client) do
      [] ->
        findings

      methods ->
        if Enum.any?(methods, &(&1 in ["none"])) do
          [
            error(
              "token endpoint auth method `none` makes the client public, " <>
                "which contradicts the #{inspect(spec.auth_methods)} this role needs"
            )
            | findings
          ]
        else
          findings
        end
    end
  end

  @doc """
  The attrs map to hand to `Defdo.Auth.Tenant.create_app/1`, built to the role's
  shape so the shape cannot be lost in transcription.
  """
  @spec attrs(role(), keyword()) :: map()
  def attrs(role \\ :instance_service, opts) do
    spec = spec(role)
    name = Keyword.fetch!(opts, :name)

    base = %{
      name: name,
      type: spec.app_type,
      auth_method: "basic",
      active: true,
      supported_grant_types: spec.required_grants,
      client: %{
        name: name,
        confidential: spec.confidential,
        redirect_uris: Keyword.get(opts, :redirect_uris, []),
        supported_grant_types: spec.required_grants,
        token_endpoint_auth_methods: spec.auth_methods
      },
      scopes: Keyword.get(opts, :scopes, []),
      skip_consent: true
    }

    opts
    |> Keyword.take([:tenant_id, :connection_id])
    |> Enum.into(base)
  end

  @doc """
  The command that registers a client with the right shape, for the next-steps
  notice the generator prints.
  """
  @spec registration_command(role(), keyword()) :: String.t()
  def registration_command(role \\ :instance_service, opts) do
    spec = spec(role)
    name = Keyword.get(opts, :name, "my_app")

    """
    mix defdo.oauth.setup #{name} <owner-email> \\
      --app-type #{spec.app_type} \\
      --supported-grant-types #{Enum.join(spec.required_grants, ",")}
    """
  end

  @doc """
  A one-line human description of a role's required shape.

      iex> Defdo.Tasks.Saas.OAuthClient.describe(:instance_service)
      "confidential, grants: client_credentials, introspect"
  """
  @spec describe(role()) :: String.t()
  def describe(role) do
    spec = spec(role)
    confidentiality = if spec.confidential, do: "confidential", else: "public"
    exactly = if spec.exact_grants?, do: " (and nothing else)", else: ""
    "#{confidentiality}, grants: #{join(spec.required_grants)}#{exactly}"
  end

  # -- normalisation ---------------------------------------------------------

  defp grants(client) do
    client
    |> get([:supported_grant_types, :grants, :grant_types])
    |> List.wrap()
    |> Enum.map(&to_string/1)
  end

  defp auth_methods(client) do
    client
    |> get([:token_endpoint_auth_methods, :token_endpoint_auth_method, :auth_method])
    |> List.wrap()
    |> Enum.map(&to_string/1)
  end

  # Deliberately not `Enum.find_value/2`: it treats a present `false` as "not
  # found", which is exactly the value that matters for `:confidential`. A public
  # client would have been read as "confidentiality not reported" and downgraded
  # from an error to a warning.
  defp get(client, keys) do
    Enum.reduce_while(keys, nil, fn key, acc ->
      case Map.fetch(client, key) do
        {:ok, value} ->
          {:halt, value}

        :error ->
          case Map.fetch(client, to_string(key)) do
            {:ok, value} -> {:halt, value}
            :error -> {:cont, acc}
          end
      end
    end)
  end

  defp error(message), do: %{severity: :error, message: message}
  defp warning(message), do: %{severity: :warning, message: message}

  defp plural([_one]), do: ""
  defp plural(_many), do: "s"

  defp join(list), do: Enum.join(list, ", ")
end
