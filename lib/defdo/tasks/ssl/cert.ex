defmodule Defdo.Tasks.Ssl.Cert do
  @moduledoc """
  Pure, testable core for `mix defdo.ssl.setup`.

  The Mix task is a thin orchestrator; everything that can be reasoned about
  without touching the network, the filesystem, or a subprocess lives here so it
  can be unit-tested:

    * `validate_project_name/1` — the name becomes a filename *and* a cert CN, so
      it is restricted to a conservative slug charset.
    * `target/0` — the host's mkcert-style target string.
    * `binary_url/1` — where the mkcert binary is fetched from.
    * `cert_paths/2` — the `priv/ssl/<name>{,_key}.pem` pair.
    * `https_block/1` and `inject/3` — the idempotent config injection.

  The two impure operations — downloading the binary and running mkcert — are
  behind injectable seams (`download/2`, `generate/2`) so callers (and tests)
  can supply their own function and never hit the network or a subprocess.

  ## The mkcert download URL is a documented default, not a verified fact

  defdo ships a custom build of `mkcert`. The exact storage URL for that build
  was not confirmed when this task was written, so the default below follows the
  same `storage.defdo.de` convention the tailwind CLI artifacts use
  (`https://storage.defdo.de/tailwind_cli_daisyui/v$version/tailwindcss-$target`)
  and the upstream mkcert release-asset naming (`mkcert-v$version-$os-$arch`).
  Treat it as a sensible default, not a guarantee. Override any part of it:

      config :defdo_tasks, :mkcert_base_url, "https://storage.defdo.de/mkcert"
      config :defdo_tasks, :mkcert_version, "1.4.4"

  or per-invocation with `--base-url`, `--version`, or the whole thing with
  `--url`.

  ## Target strings

  These follow mkcert's own Go-style release naming (`darwin-arm64`,
  `darwin-amd64`, `linux-amd64`, …), which is what a mkcert fork emits — *not*
  the `macos-x64` keys that `tailwind_compiler` uses for its manifests. Covered:
  macOS arm64/amd64 and linux amd64/arm64, with windows-amd64 for completeness.
  """

  @default_base_url "https://storage.defdo.de/mkcert"
  # Upstream mkcert's latest tag. defdo's custom build number was not verified
  # when this was written; override with --version or :mkcert_version.
  @default_version "1.4.4"

  @default_ssl_dir "priv/ssl"

  # Slug: lowercase alnum, underscores and hyphens in the middle, 1..63 chars.
  # Anchored so nothing outside the class survives — this is what keeps a name
  # like "../../etc/foo" or "a;rm -rf" out of a filename and a cert CN.
  @name_regex ~r/\A[a-z0-9](?:[a-z0-9_-]{0,61}[a-z0-9])?\z/

  @doc """
  Validates `project_name` against the safe slug charset.

  Returns `{:ok, name}` or `{:error, reason}`. The name is used both as a
  filename stem (`priv/ssl/<name>.pem`) and as a hostname handed to mkcert, so
  anything with a path separator, whitespace, uppercase, or shell metacharacter
  is rejected rather than sanitised.

      iex> Defdo.Tasks.Ssl.Cert.validate_project_name("my_app")
      {:ok, "my_app"}

      iex> Defdo.Tasks.Ssl.Cert.validate_project_name("../etc/passwd")
      {:error, :invalid_project_name}

      iex> Defdo.Tasks.Ssl.Cert.validate_project_name("")
      {:error, :empty_project_name}
  """
  @spec validate_project_name(term()) ::
          {:ok, String.t()} | {:error, :empty_project_name | :invalid_project_name}
  def validate_project_name(name) when is_binary(name) do
    cond do
      name == "" -> {:error, :empty_project_name}
      Regex.match?(@name_regex, name) -> {:ok, name}
      true -> {:error, :invalid_project_name}
    end
  end

  def validate_project_name(_), do: {:error, :invalid_project_name}

  @doc """
  Like `validate_project_name/1` but raises `Mix.Error` on a bad name.
  """
  @spec validate_project_name!(term()) :: String.t()
  def validate_project_name!(name) do
    case validate_project_name(name) do
      {:ok, name} ->
        name

      {:error, reason} ->
        Mix.raise("""
        Invalid project name #{inspect(name)} (#{reason}).

        The name becomes a filename and a certificate CN, so it must be a slug:
        lowercase letters, digits, `_` and `-`, starting and ending with a letter
        or digit, 1..63 characters. For example: my_app, defdo-status.
        """)
    end
  end

  @doc """
  The mkcert-style target string for the current host.

      "darwin-arm64" | "darwin-amd64" | "linux-amd64" | "linux-arm64" | "windows-amd64"
  """
  @spec target() :: String.t()
  def target do
    case :os.type() do
      {:win32, _} -> "windows-amd64"
      {:unix, :darwin} -> "darwin-" <> arch()
      {:unix, _} -> "linux-" <> arch()
    end
  end

  defp arch do
    a = :erlang.system_info(:system_architecture) |> List.to_string()

    cond do
      String.contains?(a, "aarch64") or String.contains?(a, "arm64") -> "arm64"
      String.contains?(a, "arm") -> "arm64"
      true -> "amd64"
    end
  end

  @doc """
  The URL the mkcert binary is downloaded from.

  Resolution order for each part: the option, then the `:defdo_tasks` config,
  then the documented default. A full `:url` option bypasses the template
  entirely.

  Options: `:url`, `:base_url`, `:version`, `:target`.
  """
  @spec binary_url(keyword()) :: String.t()
  def binary_url(opts \\ []) do
    case opts[:url] do
      url when is_binary(url) and url != "" ->
        url

      _ ->
        base =
          opts[:base_url] ||
            Application.get_env(:defdo_tasks, :mkcert_base_url, @default_base_url)

        version =
          opts[:version] || Application.get_env(:defdo_tasks, :mkcert_version, @default_version)

        target = opts[:target] || target()

        "#{String.trim_trailing(base, "/")}/v#{version}/mkcert-v#{version}-#{target}"
    end
  end

  @doc """
  The `{cert, key}` output paths for `project_name`.

  Options: `:ssl_dir` (default `"priv/ssl"`).

      iex> Defdo.Tasks.Ssl.Cert.cert_paths("my_app")
      %{cert: "priv/ssl/my_app.pem", key: "priv/ssl/my_app_key.pem"}
  """
  @spec cert_paths(String.t(), keyword()) :: %{cert: String.t(), key: String.t()}
  def cert_paths(project_name, opts \\ []) when is_binary(project_name) do
    dir = opts[:ssl_dir] || @default_ssl_dir

    %{
      cert: Path.join(dir, "#{project_name}.pem"),
      key: Path.join(dir, "#{project_name}_key.pem")
    }
  end

  @doc """
  Builds the Phoenix endpoint `https:` config block to inject.

  `endpoint` is the inspected module string (e.g. `"MyAppWeb.Endpoint"`),
  `app` the OTP app atom, `paths` the `%{cert:, key:}` map from `cert_paths/2`.

  Options:

    * `:port` — HTTPS port (default `4001`)
    * `:guard` — when `:dev`, wraps the config in `if config_env() == :dev do`
      so it is inert in prod. `config/runtime.exs` runs in every env, so the
      block injected there is guarded; `config/dev.exs` needs no guard.
  """
  @spec https_block(keyword()) :: String.t()
  def https_block(opts) do
    app = Keyword.fetch!(opts, :app)
    endpoint = Keyword.fetch!(opts, :endpoint)
    paths = Keyword.fetch!(opts, :paths)
    port = Keyword.get(opts, :port, 4001)

    config =
      """
      config #{inspect(app)}, #{endpoint},
        https: [
          port: #{port},
          cipher_suite: :strong,
          keyfile: #{inspect(paths.key)},
          certfile: #{inspect(paths.cert)}
        ]
      """
      |> String.trim_trailing()

    case Keyword.get(opts, :guard) do
      :dev ->
        "if config_env() == :dev do\n" <> indent(config, 2) <> "\nend"

      _ ->
        config
    end
  end

  @doc """
  Idempotently injects `block` into `source`, delimited by marker comments.

  If a managed region for `marker` already exists it is replaced in place (so a
  changed block updates rather than duplicates); otherwise the block is appended.
  Unrelated config is never touched. Injecting twice equals injecting once.

      iex> src = "import Config\\n"
      iex> once = Defdo.Tasks.Ssl.Cert.inject(src, "config :a, :b, 1", "demo")
      iex> twice = Defdo.Tasks.Ssl.Cert.inject(once, "config :a, :b, 1", "demo")
      iex> once == twice
      true
  """
  @spec inject(String.t(), String.t(), String.t()) :: String.t()
  def inject(source, block, marker) when is_binary(source) and is_binary(block) do
    managed = managed_block(block, marker)
    region = region_regex(marker)

    if Regex.match?(region, source) do
      Regex.replace(region, source, fn _ -> managed end)
    else
      String.trim_trailing(source) <> "\n\n" <> managed <> "\n"
    end
  end

  @doc "True if `source` already carries a managed region for `marker`."
  @spec injected?(String.t(), String.t()) :: boolean()
  def injected?(source, marker) when is_binary(source) do
    Regex.match?(region_regex(marker), source)
  end

  defp managed_block(block, marker) do
    begin_marker(marker) <> "\n" <> String.trim(block) <> "\n" <> end_marker(marker)
  end

  defp begin_marker(marker),
    do: "# BEGIN #{marker} (managed by mix defdo.ssl.setup — safe to re-run)"

  defp end_marker(marker), do: "# END #{marker}"

  defp region_regex(marker) do
    ~r/#{Regex.escape(begin_marker(marker))}.*?#{Regex.escape(end_marker(marker))}/s
  end

  defp indent(text, spaces) do
    pad = String.duplicate(" ", spaces)

    text
    |> String.split("\n")
    |> Enum.map_join("\n", fn
      "" -> ""
      line -> pad <> line
    end)
  end

  # -- step-ca on-ramp (issue defdo #4, stage 2) -----------------------------

  @default_ca_url "https://stepca.defdo.de"

  @doc """
  The step-ca URL used for the internal CA on-ramp.

  Resolution order: the `:ca_url` option, then the `:defdo_tasks` config, then
  the documented default (`#{@default_ca_url}`).

  Note this is the *passthrough* TLS endpoint (`stepca.defdo.de`), which
  presents the CA's own intermediate-signed leaf — the exact host the `step`
  CLI must talk to. The public ACME endpoint (`ca.defdo.de`) terminates a
  Let's Encrypt leaf and is only for cert-manager.
  """
  @spec step_ca_url(keyword()) :: String.t()
  def step_ca_url(opts \\ []) do
    opts[:ca_url] ||
      Application.get_env(:defdo_tasks, :step_ca_url, @default_ca_url)
  end

  @doc """
  The root CA fingerprint for `step ca bootstrap`.

  Resolution order: the `:fingerprint` option, then the `:defdo_tasks` config.
  The fingerprint is the SHA-256 of the CA's root certificate — public, not a
  secret. It pins the trust anchor so the bootstrap cannot be man-in-the-middled.
  """
  @spec step_fingerprint(keyword()) :: String.t() | nil
  def step_fingerprint(opts) do
    opts[:fingerprint] || Application.get_env(:defdo_tasks, :step_fingerprint)
  end

  @doc """
  The JWK provisioner name used to issue dev certs.

  Defaults to `"Admin JWK"` — the admin provisioner created by `enableAdmin: true`
  on the defdo CA. Use `--provisioner` to override once a dedicated dev
  provisioner exists.
  """
  @spec step_provisioner(keyword()) :: String.t()
  def step_provisioner(opts) do
    opts[:provisioner] ||
      Application.get_env(:defdo_tasks, :step_provisioner, "Admin JWK")
  end

  @doc """
  The `step` CLI invocation for `step ca bootstrap`.

  Returns `{cmd, args}`. The bootstrap writes the root cert + defaults.json into
  STEPPATH (default `~/.step`), so a later `step ca certificate` against the same
  STEPPATH trusts the CA. Idempotent: re-running re-saves the same material.
  """
  @spec step_bootstrap_cmd(keyword()) :: {String.t(), [String.t()]}
  def step_bootstrap_cmd(opts) do
    url = step_ca_url(opts)

    args =
      ["ca", "bootstrap", "--ca-url", url] ++
        case step_fingerprint(opts) do
          nil -> []
          fp -> ["--fingerprint", fp]
        end

    {"step", args}
  end

  @doc """
  The `step` CLI invocation for `step ca certificate`.

  Returns `{cmd, args}`. Issues a leaf for `subject` plus the SANs in
  `opts[:sans]`, using `opts[:provisioner]` and the provisioner password file
  from `opts[:password_file]` or `config :defdo_tasks, :step_provisioner_password_file`.
  Writes `paths.cert` / `paths.key` (the `priv/ssl` pair from `cert_paths/2`).

  The leaf lifetime defaults to `opts[:not_after]` (default `24h`) because the
  CA's `Admin JWK` provisioner pins `defaultTLSCertDuration: 5m` — far too short
  for a dev server. Override with `--not-after` (e.g. `7d`).
  """
  @spec step_certificate_cmd(String.t(), %{cert: String.t(), key: String.t()}, keyword()) ::
          {String.t(), [String.t()]}
  def step_certificate_cmd(subject, paths, opts) do
    sans = Keyword.get(opts, :sans, [])
    provisioner = step_provisioner(opts)

    password_file =
      opts[:password_file] || Application.get_env(:defdo_tasks, :step_provisioner_password_file)

    if is_nil(password_file) do
      raise ArgumentError,
            "step mode needs a provisioner password file: pass --password-file or set " <>
              "config :defdo_tasks, :step_provisioner_password_file"
    end

    not_after = opts[:not_after] || "24h"

    args =
      [
        "ca",
        "certificate",
        "--provisioner",
        provisioner,
        "--provisioner-password-file",
        password_file,
        "--not-after",
        not_after
      ] ++
        Enum.flat_map(sans, fn san -> ["--san", san] end) ++
        [subject, paths.cert, paths.key]

    {"step", args}
  end

  @doc """
  Runs a `step` CLI invocation with the given STEPPATH.

  `{cmd, args}` is the pair from `step_bootstrap_cmd/1` or
  `step_certificate_cmd/3`. The default runner shells out with `STEPPATH`
  exported. Injectable via `:runner` for tests.

  Returns `{:ok, stdout}` or `{:error, {code, stderr}}`.
  """
  @spec step_run({String.t(), [String.t()]}, keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def step_run(cmds, opts \\ []) do
    runner = Keyword.get(opts, :runner, &default_step_runner/2)
    steppath = Keyword.get(opts, :steppath, default_steppath())

    case runner.(cmds, steppath) do
      {:ok, out} ->
        {:ok, out}

      {:error, {code, out}} ->
        {:error, {:step_failed, elem(cmds, 0), code, String.slice(out, 0, 500)}}
    end
  end

  defp default_step_runner({cmd, args}, steppath) do
    env = [{"STEPPATH", steppath}]

    case System.cmd(cmd, args, env: env, stderr_to_stdout: true) do
      {out, 0} -> {:ok, out}
      {out, code} -> {:error, {code, out}}
    end
  end

  @doc "The default STEPPATH directory (`~/.step`)."
  @spec default_steppath() :: String.t()
  def default_steppath,
    do: Path.join(System.user_home!(), ".step")

  @doc """
  Returns the root cert path inside `steppath`, or nil if not bootstrapped.

  `step ca bootstrap` writes `<steppath>/certs/root_ca.crt`. Its presence is the
  idempotence signal: re-running bootstrap against an existing STEPPATH prompts
  interactively (needs a tty), so callers skip it when the root is present
  unless `:force`.
  """
  @spec step_root_path(String.t()) :: String.t() | nil
  def step_root_path(steppath) do
    candidate = Path.join([steppath, "certs", "root_ca.crt"])

    if File.exists?(candidate), do: candidate, else: nil
  end

  @doc "Bootstrap flags handed to `step ca bootstrap`."
  @spec bootstrap_flags(keyword()) :: keyword()
  def bootstrap_flags(opts), do: Keyword.take(opts, [:ca_url, :fingerprint])

  @doc """
  Downloads the mkcert binary at `url` to `dest`, returns `{:ok, dest}`.

  The default runner shells out to `curl` (a thin, injectable seam — tests pass
  their own `:runner`). The binary is made executable on unix.
  """
  @spec download(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def download(url, dest, opts \\ []) do
    runner = Keyword.get(opts, :runner, &default_download_runner/2)

    with :ok <- File.mkdir_p(Path.dirname(dest)),
         {:ok, dest} <- runner.(url, dest) do
      make_executable(dest)
      {:ok, dest}
    end
  end

  defp default_download_runner(url, dest) do
    case System.cmd("curl", ["-fsSL", "-o", dest, url], stderr_to_stdout: true) do
      {_out, 0} -> {:ok, dest}
      {out, code} -> {:error, {:download_failed, code, String.slice(out, 0, 500)}}
    end
  end

  defp make_executable(path) do
    case :os.type() do
      {:win32, _} -> :ok
      _ -> File.chmod(path, 0o755)
    end
  end

  @doc """
  Runs mkcert to write the cert/key pair for `hostnames`, returns `{:ok, paths}`.

  The default runner shells out to the mkcert binary (`mkcert_bin`). Injectable
  via `:runner` for tests.
  """
  @spec generate(String.t(), keyword()) ::
          {:ok, %{cert: String.t(), key: String.t()}} | {:error, term()}
  def generate(mkcert_bin, opts) do
    paths = Keyword.fetch!(opts, :paths)
    hostnames = Keyword.fetch!(opts, :hostnames)
    runner = Keyword.get(opts, :runner, &default_generate_runner/3)

    with :ok <- File.mkdir_p(Path.dirname(paths.cert)),
         :ok <- runner.(mkcert_bin, paths, hostnames) do
      {:ok, paths}
    end
  end

  defp default_generate_runner(mkcert_bin, paths, hostnames) do
    args = ["-cert-file", paths.cert, "-key-file", paths.key] ++ hostnames

    case System.cmd(mkcert_bin, args, stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, code} -> {:error, {:mkcert_failed, code, String.slice(out, 0, 500)}}
    end
  end
end
