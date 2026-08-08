defmodule Defdo.Tasks.RepoExtensionsTest do
  use ExUnit.Case, async: true

  alias Defdo.Tasks.Repo.Extensions
  alias Defdo.Tasks.Repo.Extensions.MissingExtensionError

  doctest Extensions

  # A repo module never needs to exist: every test injects the DB access, so no
  # connection is opened and the atom is only ever inspected into messages.
  @repo Defdo.Auth.Repo

  describe "ensure!/3 precheck" do
    test "passes when every required extension is present" do
      installed = fn _repo -> {:ok, ["plpgsql", "citext"]} end

      assert :ok =
               Extensions.ensure!(@repo, ["citext"],
                 otp_app: :defdo_auth,
                 installed_fun: installed
               )
    end

    test "raises with the remediation command when an extension is missing" do
      installed = fn _repo -> {:ok, ["plpgsql"]} end

      error =
        assert_raise MissingExtensionError, fn ->
          Extensions.ensure!(@repo, ["citext"],
            otp_app: :defdo_auth,
            installed_fun: installed
          )
        end

      assert error.missing == ["citext"]

      assert error.message =~
               ~s(database is missing extension "citext" required by defdo_auth)

      assert error.message =~
               "mix defdo.repo.pg.create_extension --name citext --repo Defdo.Auth.Repo --otp-app defdo_auth"

      assert error.message =~ "pass create_extensions: true"
    end

    test "names every missing extension when several are absent" do
      installed = fn _repo -> {:ok, []} end

      error =
        assert_raise MissingExtensionError, fn ->
          Extensions.ensure!(@repo, ["citext", "pg_trgm"],
            otp_app: :defdo_auth,
            installed_fun: installed
          )
        end

      assert error.missing == ["citext", "pg_trgm"]
      assert error.message =~ ~s(missing extensions "citext", "pg_trgm")
      assert error.message =~ "--name citext,pg_trgm"
    end
  end

  describe "ensure!/3 with create_extensions: true" do
    test "creates a missing extension when the role has rights" do
      installed = fn _repo -> {:ok, []} end
      create = fn _repo, "citext" -> :ok end

      assert :ok =
               Extensions.ensure!(@repo, ["citext"],
                 otp_app: :defdo_auth,
                 create_extensions: true,
                 installed_fun: installed,
                 create_fun: create
               )
    end

    test "falls back to the actionable error on insufficient privilege" do
      installed = fn _repo -> {:ok, []} end
      create = fn _repo, _name -> {:error, :insufficient_privilege} end

      error =
        assert_raise MissingExtensionError, fn ->
          Extensions.ensure!(@repo, ["citext"],
            otp_app: :defdo_auth,
            create_extensions: true,
            installed_fun: installed,
            create_fun: create
          )
        end

      assert error.missing == ["citext"]
      assert error.message =~ "Run: mix defdo.repo.pg.create_extension --name citext"
      assert error.message =~ "grant the migration role rights"
    end

    test "only raises for the extensions the role could not create" do
      installed = fn _repo -> {:ok, []} end

      create = fn
        _repo, "citext" -> :ok
        _repo, "pg_trgm" -> {:error, :insufficient_privilege}
      end

      error =
        assert_raise MissingExtensionError, fn ->
          Extensions.ensure!(@repo, ["citext", "pg_trgm"],
            otp_app: :defdo_auth,
            create_extensions: true,
            installed_fun: installed,
            create_fun: create
          )
        end

      assert error.missing == ["pg_trgm"]
    end
  end

  describe "name validation" do
    test "rejects an extension name that is not a safe identifier" do
      installed = fn _repo -> {:ok, []} end

      assert_raise ArgumentError, ~r/invalid Postgres extension name/, fn ->
        Extensions.ensure!(@repo, ["citext; DROP TABLE users"],
          otp_app: :defdo_auth,
          installed_fun: installed
        )
      end
    end

    test "rejection happens before the database is queried" do
      installed = fn _repo -> flunk("must not query the database for an invalid name") end

      assert_raise ArgumentError, fn ->
        Extensions.ensure!(@repo, ["bad name"],
          otp_app: :defdo_auth,
          installed_fun: installed
        )
      end
    end

    test "accepts a comma-separated string, dropping empties" do
      installed = fn _repo -> {:ok, ["citext", "pg_trgm"]} end

      assert :ok =
               Extensions.ensure!(@repo, "citext, pg_trgm,",
                 otp_app: :defdo_auth,
                 installed_fun: installed
               )
    end
  end
end
