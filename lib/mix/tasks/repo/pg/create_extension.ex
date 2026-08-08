defmodule Mix.Tasks.Defdo.Repo.Pg.CreateExtension do
  @shortdoc "Creates Postgres extensions for a defdo app"

  @moduledoc """
  Creates one or more Postgres extensions, using `psql`.

      mix defdo.repo.pg.create_extension --name citext --repo Defdo.App.Repo
      mix defdo.repo.pg.create_extension --name citext,pg_trgm --repo Defdo.App.Repo

  Like `mix defdo.repo.pg.new_schema`, this belongs in an `ecto.setup` alias:
  extensions have to exist before the migrations that use them.

  ## Options

    * `--name` — comma-separated extension names (required)
    * `--repo` — the Ecto repo module to read connection settings from (required)
    * `--otp-app` — the OTP app holding that repo's config, defaults to the
      current project
    * `--debug` — log the resolved config and repo
  """
  use Mix.Task

  alias Defdo.Tasks.Repo.Extensions
  alias Defdo.Tasks.Repo.Psql

  @impl Mix.Task
  def run([]), do: error()

  def run(args) do
    valid_options = [name: :string, repo: :string, debug: :boolean, otp_app: :string]

    case OptionParser.parse(args, strict: valid_options) do
      {opts, [], []} -> new(opts)
      {_, _, _} -> error()
    end
  end

  defp new(opts) do
    opts
    |> Psql.repo!()
    |> create_extensions(opts[:name] || error(), opts)
  end

  @doc """
  Creates the given extensions. Accepts a comma-separated string or a list.
  """
  def create_extensions(repo, extension, opts) when is_bitstring(extension) do
    create_extensions(repo, Psql.split(extension), opts)
  end

  def create_extensions(repo, extensions, opts) when is_atom(repo) and is_list(extensions) do
    config = Psql.config!(repo, opts)

    extensions
    |> Extensions.validate_names!()
    |> Enum.map_join(" ", &~s(CREATE EXTENSION IF NOT EXISTS "#{&1}";))
    |> then(&Psql.command(config, &1))
    |> Mix.shell().cmd()
  end

  defp error do
    Mix.raise("""
    Invalid arguments to defdo.repo.pg.create_extension, expected:

        mix defdo.repo.pg.create_extension --name citext --repo Defdo.App.Repo
    """)
  end
end
