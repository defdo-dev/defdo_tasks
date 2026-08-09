defmodule Defdo.Tasks.Ssl.CertTest do
  use ExUnit.Case, async: true

  alias Defdo.Tasks.Ssl.Cert

  doctest Cert

  describe "validate_project_name/1" do
    test "accepts conservative slugs" do
      for name <- ~w(my_app defdo-status a a1 defdo_tasks my-app_2) do
        assert Cert.validate_project_name(name) == {:ok, name}
      end
    end

    test "rejects the empty string distinctly" do
      assert Cert.validate_project_name("") == {:error, :empty_project_name}
    end

    test "rejects anything outside the slug charset" do
      bad = [
        "../etc/passwd",
        "foo/bar",
        "My_App",
        "app name",
        "app;rm -rf /",
        "app.pem",
        "-leading",
        "trailing-",
        "_leading",
        "a$b",
        "café",
        "a\nb"
      ]

      for name <- bad do
        assert Cert.validate_project_name(name) == {:error, :invalid_project_name},
               "expected #{inspect(name)} to be rejected"
      end
    end

    test "rejects names longer than 63 chars but accepts exactly 63" do
      assert Cert.validate_project_name(String.duplicate("a", 63)) ==
               {:ok, String.duplicate("a", 63)}

      assert Cert.validate_project_name(String.duplicate("a", 64)) ==
               {:error, :invalid_project_name}
    end

    test "rejects non-binaries" do
      assert Cert.validate_project_name(nil) == {:error, :invalid_project_name}
      assert Cert.validate_project_name(:my_app) == {:error, :invalid_project_name}
    end

    test "bang version raises Mix.Error with guidance" do
      assert_raise Mix.Error, ~r/must be a slug/, fn ->
        Cert.validate_project_name!("Bad Name")
      end
    end
  end

  describe "cert_paths/2" do
    test "defaults to priv/ssl" do
      assert Cert.cert_paths("my_app") == %{
               cert: "priv/ssl/my_app.pem",
               key: "priv/ssl/my_app_key.pem"
             }
    end

    test "honours a custom ssl_dir" do
      assert Cert.cert_paths("my_app", ssl_dir: "tmp/certs") == %{
               cert: "tmp/certs/my_app.pem",
               key: "tmp/certs/my_app_key.pem"
             }
    end
  end

  describe "target/0" do
    test "is one of the supported mkcert target strings" do
      assert Cert.target() in ~w(darwin-arm64 darwin-amd64 linux-amd64 linux-arm64 windows-amd64)
    end
  end

  describe "binary_url/1" do
    test "builds the storage.defdo URL from base, version and target" do
      url =
        Cert.binary_url(
          base_url: "https://storage.defdo.de/mkcert",
          version: "1.4.4",
          target: "linux-amd64"
        )

      assert url == "https://storage.defdo.de/mkcert/v1.4.4/mkcert-v1.4.4-linux-amd64"
    end

    test "a trailing slash on base_url does not double up" do
      url =
        Cert.binary_url(
          base_url: "https://example.com/mkcert/",
          version: "9",
          target: "darwin-arm64"
        )

      assert url == "https://example.com/mkcert/v9/mkcert-v9-darwin-arm64"
    end

    test "a full :url overrides the template" do
      assert Cert.binary_url(url: "https://example.com/custom") == "https://example.com/custom"
    end

    test "config supplies defaults" do
      Application.put_env(:defdo_tasks, :mkcert_base_url, "https://cfg.example/mk")
      Application.put_env(:defdo_tasks, :mkcert_version, "2.0.0")

      on_exit(fn ->
        Application.delete_env(:defdo_tasks, :mkcert_base_url)
        Application.delete_env(:defdo_tasks, :mkcert_version)
      end)

      assert Cert.binary_url(target: "linux-amd64") ==
               "https://cfg.example/mk/v2.0.0/mkcert-v2.0.0-linux-amd64"
    end
  end

  describe "https_block/1" do
    setup do
      %{paths: Cert.cert_paths("my_app")}
    end

    test "renders an endpoint https block", %{paths: paths} do
      block = Cert.https_block(app: :my_app, endpoint: "MyAppWeb.Endpoint", paths: paths)

      assert block =~ "config :my_app, MyAppWeb.Endpoint,"
      assert block =~ "https: ["
      assert block =~ ~s(keyfile: "priv/ssl/my_app_key.pem")
      assert block =~ ~s(certfile: "priv/ssl/my_app.pem")
      assert block =~ "port: 4001"
      refute block =~ "config_env()"
    end

    test "honours a custom port", %{paths: paths} do
      block =
        Cert.https_block(app: :my_app, endpoint: "MyAppWeb.Endpoint", paths: paths, port: 4443)

      assert block =~ "port: 4443"
    end

    test "the :dev guard wraps the block for runtime.exs", %{paths: paths} do
      block =
        Cert.https_block(app: :my_app, endpoint: "MyAppWeb.Endpoint", paths: paths, guard: :dev)

      assert block =~ "if config_env() == :dev do"
      assert block =~ "\nend"
      assert block =~ "  config :my_app, MyAppWeb.Endpoint,"
    end
  end

  describe "inject/3 idempotency" do
    @source """
    import Config

    config :my_app, MyAppWeb.Endpoint,
      http: [ip: {127, 0, 0, 1}, port: 4000],
      debug_errors: true
    """

    @block ~s(config :my_app, MyAppWeb.Endpoint,\n  https: [port: 4001])

    test "injecting twice equals injecting once" do
      once = Cert.inject(@source, @block, "defdo_tasks:https")
      twice = Cert.inject(once, @block, "defdo_tasks:https")

      assert once == twice
    end

    test "the block appears exactly once after repeated injection" do
      result =
        @source
        |> Cert.inject(@block, "defdo_tasks:https")
        |> Cert.inject(@block, "defdo_tasks:https")
        |> Cert.inject(@block, "defdo_tasks:https")

      assert count(result, "BEGIN defdo_tasks:https") == 1
      assert count(result, "END defdo_tasks:https") == 1
      assert count(result, "https: [port: 4001]") == 1
    end

    test "never clobbers unrelated config" do
      result = Cert.inject(@source, @block, "defdo_tasks:https")

      assert result =~ "http: [ip: {127, 0, 0, 1}, port: 4000]"
      assert result =~ "debug_errors: true"
    end

    test "a changed block updates in place instead of appending" do
      once = Cert.inject(@source, @block, "defdo_tasks:https")

      changed =
        Cert.inject(
          once,
          ~s(config :my_app, MyAppWeb.Endpoint,\n  https: [port: 9999]),
          "defdo_tasks:https"
        )

      assert changed =~ "port: 9999"
      refute changed =~ "port: 4001"
      assert count(changed, "BEGIN defdo_tasks:https") == 1
    end

    test "injected?/2 reports presence" do
      refute Cert.injected?(@source, "defdo_tasks:https")

      assert Cert.injected?(
               Cert.inject(@source, @block, "defdo_tasks:https"),
               "defdo_tasks:https"
             )
    end
  end

  describe "download/3 and generate/2 seams" do
    test "download/3 uses the injected runner and makes the dir" do
      dest =
        Path.join(
          System.tmp_dir!(),
          "defdo_mkcert_test_#{System.unique_integer([:positive])}/mkcert"
        )

      on_exit(fn -> File.rm_rf(Path.dirname(dest)) end)

      runner = fn url, d ->
        send(self(), {:downloaded, url, d})
        File.write!(d, "#!/bin/sh\n")
        {:ok, d}
      end

      assert {:ok, ^dest} = Cert.download("https://example.com/mkcert", dest, runner: runner)
      assert File.exists?(dest)
      assert_received {:downloaded, "https://example.com/mkcert", ^dest}
    end

    test "generate/2 uses the injected runner and passes both hostnames" do
      paths =
        Cert.cert_paths("my_app",
          ssl_dir: Path.join(System.tmp_dir!(), "defdo_ssl_#{System.unique_integer([:positive])}")
        )

      on_exit(fn -> File.rm_rf(Path.dirname(paths.cert)) end)

      runner = fn bin, ps, hostnames ->
        send(self(), {:generated, bin, ps, hostnames})
        :ok
      end

      assert {:ok, ^paths} =
               Cert.generate("/usr/bin/mkcert",
                 paths: paths,
                 hostnames: ["my_app", "localhost"],
                 runner: runner
               )

      assert_received {:generated, "/usr/bin/mkcert", ^paths, ["my_app", "localhost"]}
    end

    test "generate/2 surfaces the runner error" do
      paths =
        Cert.cert_paths("my_app",
          ssl_dir: Path.join(System.tmp_dir!(), "defdo_ssl_#{System.unique_integer([:positive])}")
        )

      on_exit(fn -> File.rm_rf(Path.dirname(paths.cert)) end)

      runner = fn _bin, _ps, _hostnames -> {:error, {:mkcert_failed, 1, "boom"}} end

      assert {:error, {:mkcert_failed, 1, "boom"}} =
               Cert.generate("mkcert",
                 paths: paths,
                 hostnames: ["a", "localhost"],
                 runner: runner
               )
    end
  end

  describe "step-ca on-ramp helpers" do
    test "step_ca_url/1 resolves option, config, then default" do
      assert Cert.step_ca_url(ca_url: "https://override.defdo") == "https://override.defdo"

      assert Cert.step_ca_url([]) == "https://stepca.defdo.de"
    end

    test "step_fingerprint/1 takes option or config" do
      assert Cert.step_fingerprint(fingerprint: "abc") == "abc"
      assert Cert.step_fingerprint([]) == nil
    end

    test "step_provisioner/1 defaults to Admin JWK" do
      assert Cert.step_provisioner([]) == "Admin JWK"
      assert Cert.step_provisioner(provisioner: "Dev JWK") == "Dev JWK"
    end

    test "step_bootstrap_cmd/1 builds bootstrap invocation with fingerprint" do
      {"step", args} =
        Cert.step_bootstrap_cmd(
          ca_url: "https://stepca.defdo.de",
          fingerprint: "fp123"
        )

      assert args == [
               "ca",
               "bootstrap",
               "--ca-url",
               "https://stepca.defdo.de",
               "--fingerprint",
               "fp123"
             ]
    end

    test "step_bootstrap_cmd/1 omits fingerprint when absent" do
      {"step", args} = Cert.step_bootstrap_cmd(ca_url: "https://stepca.defdo.de")

      assert args == ["ca", "bootstrap", "--ca-url", "https://stepca.defdo.de"]
    end

    test "step_certificate_cmd/3 builds issue invocation with SANs and pos args" do
      paths = %{cert: "priv/ssl/my_app.pem", key: "priv/ssl/my_app_key.pem"}

      {"step", args} =
        Cert.step_certificate_cmd("my_app", paths,
          provisioner: "Admin JWK",
          password_file: "/tmp/pw",
          sans: ["my_app", "localhost", "127.0.0.1"]
        )

      assert args == [
               "ca",
               "certificate",
               "--provisioner",
               "Admin JWK",
               "--provisioner-password-file",
               "/tmp/pw",
               "--not-after",
               "24h",
               "--san",
               "my_app",
               "--san",
               "localhost",
               "--san",
               "127.0.0.1",
               "my_app",
               "priv/ssl/my_app.pem",
               "priv/ssl/my_app_key.pem"
             ]
    end

    test "step_certificate_cmd/3 requires password_file" do
      paths = %{cert: "c.pem", key: "k.pem"}

      assert_raise KeyError, fn ->
        Cert.step_certificate_cmd("my_app", paths, sans: ["localhost"])
      end
    end

    test "step_root_path/1 returns nil when not bootstrapped" do
      dir = Path.join(System.tmp_dir!(), "step_empty_#{System.unique_integer([:positive])}")

      assert Cert.step_root_path(dir) == nil
    end

    test "step_root_path/1 returns root cert path when bootstrapped" do
      dir = Path.join(System.tmp_dir!(), "step_root_#{System.unique_integer([:positive])}")

      File.mkdir_p!(Path.join(dir, "certs"))
      root = Path.join([dir, "certs", "root_ca.crt"])
      File.write!(root, "root")
      on_exit(fn -> File.rm_rf(dir) end)

      assert Cert.step_root_path(dir) == root
    end

    test "step_run/2 surfaces runner errors uniformly" do
      runner = fn _, _ -> {:error, {7, "boom"}} end

      assert {:error, {:step_failed, "step", 7, "boom"}} =
               Cert.step_run({"step", ["ca", "bootstrap"]}, runner: runner)
    end

    test "step_run/2 passes the resolved steppath to the runner" do
      paths = Cert.cert_paths("my_app")

      # pre-create root so bootstrap is skipped by the caller, but here we only
      # assert the runner receives a steppath.
      cert_cmd = Cert.step_certificate_cmd("my_app", paths, password_file: "pw")

      runner = fn {cmd, _args}, steppath ->
        send(self(), {:ran, cmd, steppath})
        {:ok, "out"}
      end

      assert {:ok, "out"} = Cert.step_run(cert_cmd, steppath: "/tmp/sp", runner: runner)
      assert_received {:ran, "step", "/tmp/sp"}
    end
  end

  defp count(haystack, needle) do
    haystack |> String.split(needle) |> length() |> Kernel.-(1)
  end
end
