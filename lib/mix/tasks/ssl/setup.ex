defmodule Mix.Tasks.Defdo.Ssl.Setup do
  @shortdoc "Sets up local dev HTTPS certs (defdo mkcert or step-ca) and wires the Phoenix endpoint"

  @moduledoc """
  Sets up locally-trusted HTTPS for a defdo app.

  Two backends, selected with `--mode`:

    * `--mode mkcert` (default) — downloads defdo's custom build of `mkcert`
      and generates a locally-trusted root + cert on this machine.
    * `--mode step` — on-ramps to the internal defdo CA (issue #4 stage 2):
      `step ca bootstrap` pins the CA root by fingerprint, then `step ca
      certificate` issues a leaf signed by the CA's intermediate. Same UX, real
      internal PKI instead of a per-machine mkcert root.

      mix defdo.ssl.setup --mode step
      mix defdo.ssl.setup --mode step --password-file ~/.step/password

      The `--password-file` is the CA provisioner password (the `Admin JWK`
      provisioner created by `enableAdmin: true`). Keep it out of git.

  What it does, all idempotently:

    1. Ensures the certs exist for `<project>` + `localhost` (mkcert) or issues
       them from the internal CA (step), writing `priv/ssl/<project>.pem` and
       `priv/ssl/<project>_key.pem` (re-used unless `--force`).
    2. Injects an `https:` endpoint block into `config/dev.exs` and
       `config/runtime.exs`, delimited by marker comments so re-running updates
       the block in place instead of duplicating it, and never touches unrelated
       config. Phoenix merges the `https:` key into the endpoint config you
       already have; the existing `http:` block is left alone.
    3. Ensures `priv/ssl/*.pem` is gitignored — these are secrets-adjacent.

  ## The mkcert download URL

  defdo ships a custom mkcert build. The default download URL follows the
  `storage.defdo.de` convention and upstream mkcert's asset naming, but the
  exact URL for the custom build was not verified when this task was written.
  It is a sensible default, not a guarantee — override it if it 404s:

      config :defdo_tasks, :mkcert_base_url, "https://storage.defdo.de/mkcert"
      config :defdo_tasks, :mkcert_version, "1.4.4"

  or `--base-url`, `--version`, or the whole URL with `--url`.

  ## step-ca on-ramp (mode step)

  The `step` CLI talks to the CA's passthrough TLS endpoint
  (`https://stepca.defdo.de`) — the host that presents the CA's own
  intermediate-signed leaf. The public ACME endpoint (`ca.defdo.de`) terminates
  a Let's Encrypt leaf and is only for cert-manager.

  The root is pinned by fingerprint:

      config :defdo_tasks, :step_fingerprint, "<root-sha256>"

  or `--fingerprint`. The fingerprint is the SHA-256 of the CA root — public.
  Override the CA URL with `--ca-url` or `config :defdo_tasks, :step_ca_url`.
  Override the provisioner with `--provisioner` (default `Admin JWK`).
  Override the STEPPATH with `--step-path` (default `~/.step`).

  ## Options

    * `--mode` — `mkcert` (default) or `step`.
    * `--project` — project name; the cert filename stem and a cert CN. Defaults
      to the current Mix project's app name. Must be a slug
      (`[a-z0-9_-]`, starts/ends alnum).
    * `--endpoint` — the Phoenix endpoint module (e.g. `MyAppWeb.Endpoint`).
      Defaults to `<CamelApp>Web.Endpoint`.
    * `--app` — the OTP app for the endpoint config. Defaults to the Mix project.
    * `--port` — the HTTPS port to configure. Defaults to `4001`.
    * `--url` — full mkcert download URL, bypasses the template.
    * `--base-url` — mkcert download base URL.
    * `--version` — mkcert version.
    * `--force` — re-download the binary / re-issue the cert even if present.
    * `--ca-url` — step-ca URL (default `https://stepca.defdo.de`).
    * `--fingerprint` — root CA SHA-256 fingerprint (step mode).
    * `--provisioner` — step provisioner (default `Admin JWK`).
    * `--password-file` — step provisioner password file (step mode).
    * `--step-path` — STEPPATH (default `~/.step`).
    * `--not-after` — leaf validity duration (step mode, default `24h`).
  """

  use Mix.Task

  alias Defdo.Tasks.Ssl.Cert

  @marker "defdo_tasks:https"
  @dev_config "config/dev.exs"
  @runtime_config "config/runtime.exs"
  @gitignore ".gitignore"

  @switches [
    mode: :string,
    project: :string,
    endpoint: :string,
    app: :string,
    port: :integer,
    url: :string,
    base_url: :string,
    version: :string,
    force: :boolean,
    ca_url: :string,
    fingerprint: :string,
    provisioner: :string,
    password_file: :string,
    step_path: :string,
    not_after: :string
  ]

  @impl Mix.Task
  def run(args) do
    {opts, rest} = OptionParser.parse!(args, strict: @switches)

    if rest != [], do: Mix.raise("unexpected argument(s): #{Enum.join(rest, " ")}")

    mode = opts[:mode] || "mkcert"

    app = resolve_app(opts)
    project = Cert.validate_project_name!(opts[:project] || to_string(app))
    endpoint = opts[:endpoint] || default_endpoint(app)
    paths = Cert.cert_paths(project)

    ensure_certs(mode, project, paths, opts)
    inject_configs(app, endpoint, paths, opts)
    ensure_gitignore()

    Mix.shell().info("""

    HTTPS is set up. Restart the server and open https://localhost:#{opts[:port] || 4001}.

      cert: #{paths.cert}
      key:  #{paths.key}
    """)
  end

  # -- certs ----------------------------------------------------------------

  defp ensure_certs("step", project, paths, opts) do
    ensure_step_certs(project, paths, opts)
  end

  defp ensure_certs(_mode, project, paths, opts) do
    ensure_mkcert_certs(project, paths, opts)
  end

  defp ensure_step_certs(project, paths, opts) do
    if certs_present?(paths) and !opts[:force] do
      Mix.shell().info("Certs already exist (#{paths.cert}); reusing. Pass --force to re-issue.")
    else
      steppath = opts[:step_path] || Cert.default_steppath()

      if Cert.step_root_path(steppath) do
        Mix.shell().info("step ca bootstrap: root already present in #{steppath}; skipping.")
      else
        case Cert.step_run(Cert.step_bootstrap_cmd(opts), steppath: steppath) do
          {:ok, _out} ->
            Mix.shell().info("step ca bootstrap: trusted defdo CA root.")

          {:error, reason} ->
            Mix.raise("step ca bootstrap failed: #{inspect(reason)}")
        end
      end

      sans = [project, "localhost", "127.0.0.1"]

      File.mkdir_p!(Path.dirname(paths.cert))

      if opts[:force] do
        # `step ca certificate` prompts interactively when the output files already
        # exist; remove them so a forced re-issue runs non-interactively.
        File.rm(paths.cert)
        File.rm(paths.key)
      end

      cert_cmd = Cert.step_certificate_cmd(project, paths, Keyword.put(opts, :sans, sans))

      case Cert.step_run(cert_cmd, steppath: steppath) do
        {:ok, _out} ->
          Mix.shell().info("Issued cert for #{project} and localhost from the defdo CA.")

        {:error, reason} ->
          Mix.raise("step ca certificate failed: #{inspect(reason)}")
      end
    end
  end

  defp ensure_mkcert_certs(project, paths, opts) do
    if certs_present?(paths) and !opts[:force] do
      Mix.shell().info(
        "Certs already exist (#{paths.cert}); reusing. Pass --force to regenerate."
      )
    else
      mkcert = ensure_binary(opts)

      case Cert.generate(mkcert, paths: paths, hostnames: [project, "localhost"]) do
        {:ok, _paths} ->
          Mix.shell().info("Generated cert for #{project} and localhost.")

        {:error, reason} ->
          Mix.raise("mkcert failed: #{inspect(reason)}")
      end
    end
  end

  defp certs_present?(paths), do: File.exists?(paths.cert) and File.exists?(paths.key)

  defp ensure_binary(opts) do
    dest =
      Path.join([Mix.Project.build_path(), "defdo_mkcert", Cert.target(), "mkcert"])

    if File.exists?(dest) and !opts[:force] do
      dest
    else
      url = Cert.binary_url(Keyword.take(opts, [:url, :base_url, :version]))
      Mix.shell().info("Downloading mkcert from #{url}")

      case Cert.download(url, dest) do
        {:ok, dest} ->
          dest

        {:error, reason} ->
          Mix.raise("""
          Could not download the mkcert binary from:

              #{url}

          Reason: #{inspect(reason)}

          The default URL is a documented convention, not a verified fact. Override it
          with --url, --base-url or --version, or config :defdo_tasks, :mkcert_base_url.
          """)
      end
    end
  end

  # -- config injection -----------------------------------------------------

  defp inject_configs(app, endpoint, paths, opts) do
    port = opts[:port] || 4001

    inject_file(
      @dev_config,
      Cert.https_block(app: app, endpoint: endpoint, paths: paths, port: port)
    )

    inject_file(
      @runtime_config,
      Cert.https_block(app: app, endpoint: endpoint, paths: paths, port: port, guard: :dev)
    )
  end

  defp inject_file(path, block) do
    case File.read(path) do
      {:ok, source} ->
        updated = Cert.inject(source, block, @marker)

        if updated == source do
          Mix.shell().info("#{path}: HTTPS block already present; unchanged.")
        else
          File.write!(path, updated)
          Mix.shell().info("#{path}: HTTPS block injected.")
        end

      {:error, :enoent} ->
        Mix.shell().error("#{path} not found; skipped. Add the https: endpoint config by hand.")
    end
  end

  # -- gitignore ------------------------------------------------------------

  defp ensure_gitignore do
    entry = "/priv/ssl/*.pem"

    source =
      case File.read(@gitignore) do
        {:ok, source} -> source
        {:error, :enoent} -> ""
      end

    if String.contains?(source, "priv/ssl/") do
      :ok
    else
      block =
        "\n# Local dev HTTPS certs (secrets-adjacent, generated by mix defdo.ssl.setup)\n#{entry}\n"

      File.write!(@gitignore, String.trim_trailing(source) <> "\n" <> block)
      Mix.shell().info("#{@gitignore}: added #{entry}")
    end
  end

  # -- resolution -----------------------------------------------------------

  defp resolve_app(opts) do
    case opts[:app] do
      nil ->
        Mix.Project.config()[:app] || Mix.raise("could not determine the OTP app; pass --app")

      app ->
        String.to_atom(app)
    end
  end

  defp default_endpoint(app) do
    "#{Macro.camelize(to_string(app))}Web.Endpoint"
  end
end
