defmodule Defdo.Tasks.Saas.OAuthClientTest do
  use ExUnit.Case, async: true

  alias Defdo.Tasks.Saas.OAuthClient

  doctest OAuthClient

  defp messages({:error, findings}), do: Enum.map(findings, & &1.message)

  describe "validate/2 for :instance_service" do
    test "the correct shape passes" do
      assert :ok =
               OAuthClient.validate(%{
                 supported_grant_types: ["client_credentials", "introspect"],
                 confidential: true,
                 token_endpoint_auth_methods: ["client_secret_basic", "client_secret_post"]
               })
    end

    test "extra grants are allowed -- only the required two are required" do
      assert :ok =
               OAuthClient.validate(%{
                 supported_grant_types: [
                   "client_credentials",
                   "introspect",
                   "authorization_code",
                   "refresh_token"
                 ],
                 confidential: true
               })
    end

    test "the m2m preset fails: client_credentials with no introspect" do
      # `Defdo.Auth.OAuth.AppTypePreset`'s "m2m" entry ships exactly this, which
      # is the likeliest reason 4 of 12 registered applications cannot introspect.
      result =
        OAuthClient.validate(%{supported_grant_types: ["client_credentials"], confidential: true})

      assert [message] = messages(result)
      assert message =~ "introspect"
    end

    test "the refresh-only client is named for what it actually is" do
      result =
        OAuthClient.validate(%{
          supported_grant_types: ["refresh_token", "revoke"],
          confidential: true
        })

      messages = messages(result)

      assert Enum.any?(messages, &(&1 =~ "can never obtain"))
      assert Enum.any?(messages, &(&1 =~ "client_credentials"))
    end

    test "a public client fails, because both grants need a secret" do
      result =
        OAuthClient.validate(%{
          supported_grant_types: ["client_credentials", "introspect"],
          confidential: false
        })

      assert [message] = messages(result)
      assert message =~ "public"
    end

    test "auth method none fails even when confidential says true" do
      result =
        OAuthClient.validate(%{
          supported_grant_types: ["client_credentials", "introspect"],
          confidential: true,
          token_endpoint_auth_methods: ["none"]
        })

      assert [message] = messages(result)
      assert message =~ "none"
    end

    test "an unreported confidential flag warns but does not fail" do
      assert :ok =
               OAuthClient.validate(%{
                 supported_grant_types: ["client_credentials", "introspect"]
               })
    end

    test "accepts the field names the estate actually uses" do
      for key <- [:supported_grant_types, :grants, :grant_types, "supported_grant_types"] do
        client = %{key => ["client_credentials", "introspect"], :confidential => true}
        assert :ok = OAuthClient.validate(client), "failed for key #{inspect(key)}"
      end
    end

    test "accepts atom grants as well as strings" do
      assert :ok =
               OAuthClient.validate(%{
                 grants: [:client_credentials, :introspect],
                 confidential: true
               })
    end
  end

  describe "validate/2 for :platform_introspection" do
    test "introspect alone passes" do
      assert :ok =
               OAuthClient.validate(
                 %{supported_grant_types: ["introspect"], confidential: true},
                 :platform_introspection
               )
    end

    test "adding client_credentials disqualifies it" do
      # `Defdo.Auth.OAuth.PlatformIntrospection` classifies a client as a
      # platform client only when every grant it holds is `introspect`. The
      # shape that is required for :instance_service is fatal here, which is
      # why this module carries two roles instead of one.
      result =
        OAuthClient.validate(
          %{supported_grant_types: ["client_credentials", "introspect"], confidential: true},
          :platform_introspection
        )

      assert [message] = messages(result)
      assert message =~ "disqualify"
    end

    test "the two roles cannot be satisfied by one client" do
      client = %{supported_grant_types: ["client_credentials", "introspect"], confidential: true}

      assert :ok = OAuthClient.validate(client, :instance_service)
      assert {:error, _} = OAuthClient.validate(client, :platform_introspection)
    end
  end

  describe "attrs/2" do
    test "builds a client that validates against its own role" do
      attrs = OAuthClient.attrs(:instance_service, name: "my_app")

      assert :ok = OAuthClient.validate(attrs.client, :instance_service)
      assert attrs.name == "my_app"
      assert attrs.client.confidential == true
    end

    test "carries tenant and connection through when given" do
      attrs = OAuthClient.attrs(:instance_service, name: "a", tenant_id: "t", connection_id: "c")

      assert attrs.tenant_id == "t"
      assert attrs.connection_id == "c"
    end

    test "omits tenant and connection when not given, rather than nulling them" do
      attrs = OAuthClient.attrs(:instance_service, name: "a")

      refute Map.has_key?(attrs, :tenant_id)
      refute Map.has_key?(attrs, :connection_id)
    end
  end

  describe "registration_command/2" do
    test "names both grants the role needs" do
      command = OAuthClient.registration_command(:instance_service, name: "my_app")

      assert command =~ "client_credentials,introspect"
      assert command =~ "my_app"
    end
  end
end
