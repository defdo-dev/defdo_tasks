defmodule Mix.Tasks.Defdo.Ssl.Setup do
  @shortdoc "Generates local dev HTTPS certs (defdo mkcert) and wires the Phoenix endpoint"

  @moduledoc """
  Sets up locally-trusted HTTPS for a defdo app using defdo's custom build of
  `mkcert`.

      mix defdo.ssl.setup
      mix defdo.ssl.setup --project my_app
      mix defdo.ssl.setup --force

  What it does, all idempotently:

    1. Downloads the defdo `mkcert` binary for this host (cached under
       `_build`; re-used unless `--force`).
    2. Generates a cert for `<project>` and `localhost`, writing
       `priv/ssl/<project>.pem` and `priv/ssl/<project>_key.pem` (re-used unless
       `--force`).
    3. Injects an `https:` endpoint block into `config/dev.exs` and
       `config/runtime.exs`, delimited by marker comments so re-running updates
       the block in place instead of duplicating it, and never touches unrelated
       config. Phoenix merges the `https:` key into the endpoint config you
       already have; the existing `http:` block is left alone.
    4. Ensures `priv/ssl/*.pem` is gitignored — these are secrets-adjacent.

  ## The mkcert download URL

  defdo ships a custom mkcert build. The default download URL follows the
  `storage.defdo.de` convention and upstream mkcert's asset naming, but the
  exact URL for the custom build was not verified when this task was written.
  It is a sensible default, not a guarantee — override it if it 404s:

      config :defdo_tasks, :mkcert_base_url, "https://storage.defdo.de/mkcert"
      config :defdo_tasks, :mkcert_version, "1.4.4"

  or `--base-url`, `--version`, or the whole URL with `--url`.

  ## Options

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
    * `--force` — re-download the binary and regenerate the cert even if present.
  """

  use Mix.Task

  alias Defdo.Tasks.Ssl.Cert

  @marker "defdo_tasks:https"
  @dev_config "config/dev.exs"
  @runtime_config "config/runtime.exs"
  @gitignore ".gitignore"

  @switches [
    project: :string,
    endpoint: :string,
    app: :string,
    port: :integer,
    url: :string,
    base_url: :string,
    version: :string,
    force: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    {opts, rest} = OptionParser.parse!(args, strict: @switches)

    if rest != [], do: Mix.raise("unexpected argument(s): #{Enum.join(rest, " ")}")

    app = resolve_app(opts)
    project = Cert.validate_project_name!(opts[:project] || to_string(app))
    endpoint = opts[:endpoint] || default_endpoint(app)
    paths = Cert.cert_paths(project)

    ensure_certs(project, paths, opts)
    inject_configs(app, endpoint, paths, opts)
    ensure_gitignore()

    Mix.shell().info("""

    HTTPS is set up. Restart the server and open https://localhost:#{opts[:port] || 4001}.

      cert: #{paths.cert}
      key:  #{paths.key}
    """)
  end

  # -- certs ----------------------------------------------------------------

  defp ensure_certs(project, paths, opts) do
    if certs_present?(paths) and not opts[:force] do
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

    if File.exists?(dest) and not opts[:force] do
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
