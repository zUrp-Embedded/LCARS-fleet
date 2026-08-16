defmodule Fleet.Project.TemplateSync do
  @moduledoc """
  Force-projects the local project-template source onto its forge template repo, marks it
  native-template, and seeds the protocol labels.

  ## Why this is a module and not (only) a Mix task

  It WAS only a Mix task, and that made it unreachable exactly where it is needed. `mix` is a
  build-time tool: the runtime image ships the release and no toolchain (`15-toolchain`:
  "build only, jamais dans le conteneur runtime"). So the one thing that poses the template on a
  forge could not run on a deployed box — and nothing outside the bench ever called it. A
  production forge therefore had no `project-template`, and `Onboard` silently degraded to
  bare-create on every project it opened.

  The body never needed Mix: it only ever used `Fleet.*`. It lives here, and the Mix task is now a
  thin front for it — same door as `Fleet.Application.CatalogueRoles` and `CatalogueVerify`, which
  a release already exposes through `lcars_fleet eval`.

  ## Credentials

  `sync/1` takes `base_url:` and `token:` explicitly. It NEVER reads a running fleet's config: this
  runs beside a deployment, not inside one, and a caller that must name its forge cannot aim at the
  wrong one by accident.

  ## Transport

  The forge client rides an app-supervised Finch pool. Callers that run WITHOUT the app started
  (a Mix task, a release `eval`) use `standalone_sync/1`, which starts the very same child spec
  under a local supervisor — `Fleet.Forge.finch_spec/0`, the pool's OWN declaration, and not the
  Pilot delegation the Mix task used to reach for (Project may not depend on Pilot, and the spec
  never belonged to Pilot in the first place).
  """

  # Every git op runs on the WORLD side (outside any sandbox) — compose the runtime's SINGLE-SOURCE
  # config neutralization (hooks/fsmonitor/sshCommand/diff.external) so a `.gitattributes`/config
  # shipped in the template tree cannot execute code here. Same invariant as Fleet.Workflow.Git.
  @hooks_off Fleet.Credentials.Shell.git_safe_config_args()

  # WALL bounds (SIGKILL of the OS process-group at the deadline, via Shell.git). Local ops
  # are sub-second; the NETWORK push is the one that could hang a deploy forever without a bound.
  @local_timeout_ms 30_000
  @push_timeout_ms 60_000

  @doc """
  Starts the transport this needs, then syncs. For callers with no running app — a Mix task, a
  release `eval`. Returns `{:ok, repo}` or `{:error, reason}`.
  """
  @spec standalone_sync(keyword()) :: {:ok, String.t()} | {:error, term()}
  def standalone_sync(fc) do
    with {:ok, _} <- Application.ensure_all_started(:req),
         {:ok, _} <-
           Supervisor.start_link([Fleet.Forge.finch_spec()], strategy: :one_for_one) do
      sync(fc)
    else
      {:error, reason} -> {:error, {:transport, reason}}
    end
  end

  @doc """
  Syncs the template repo. Requires `base_url:` and `token:`, and a transport already up.
  """
  @spec sync(keyword()) :: {:ok, String.t()} | {:error, term()}
  def sync(fc) do
    repo = Fleet.Project.Onboard.project_template()
    [org, name] = String.split(repo, "/", parts: 2)

    with :ok <- ensure_repo(org, name, repo, fc),
         :ok <- push_template(repo, fc),
         :ok <- Fleet.Forge.Client.Repo.set_template(repo, true, fc),
         :ok <- Fleet.Forge.Client.ensure_protocol_labels(repo, fc) do
      {:ok, repo}
    end
  end

  @doc """
  Credentials from the environment: `FORGE_BASE_URL` + `FORGE_TOKEN_FILE`. Both must be named —
  a default forge would be the wrong forge on the day it matters.
  """
  @spec forge_opts_from_env() :: {:ok, keyword()} | {:error, term()}
  def forge_opts_from_env do
    with {:base, base} when is_binary(base) <- {:base, System.get_env("FORGE_BASE_URL")},
         {:file, file} when is_binary(file) <- {:file, System.get_env("FORGE_TOKEN_FILE")},
         {:ok, token} <- File.read(file) do
      {:ok, [base_url: base, token: String.trim(token)]}
    else
      {:base, nil} -> {:error, :forge_base_url_missing}
      {:file, nil} -> {:error, :forge_token_file_missing}
      {:error, posix} -> {:error, {:forge_token_file_unreadable, posix}}
    end
  end

  @doc """
  Release door: reads the environment, syncs, prints ONE line, and halts with a code. Same shape as
  `Fleet.Application.CatalogueRoles.eval_main/1` — the motive goes to stderr so a caller capturing
  stdout gets an empty string on failure, never a message it might mistake for a repo name.
  """
  @spec eval_main() :: no_return()
  def eval_main do
    case forge_opts_from_env() do
      {:ok, fc} ->
        case standalone_sync(fc) do
          {:ok, repo} ->
            IO.puts("project-template: #{repo} synced (content + template flag + labels)")
            System.halt(0)

          {:error, reason} ->
            IO.puts(:stderr, "project-template: sync FAILED: #{inspect(reason)}")
            System.halt(1)
        end

      {:error, reason} ->
        IO.puts(:stderr, "project-template: #{inspect(reason)}")
        System.halt(2)
    end
  end

  defp ensure_repo(org, name, repo, fc) do
    case Fleet.Forge.Client.Repo.create_repo(
           name,
           Keyword.merge(fc,
             org: org,
             description: "Modèle de projet fleet — projeté depuis le catalogue en service",
             auto_init: false
           )
         ) do
      {:ok, :already_exists} -> :ok
      {:ok, ^repo} -> :ok
      {:ok, other} when is_binary(other) -> :ok
      {:error, _} = err -> err
    end
  end

  # Force-push BOTH faces of the priv tree, each as a single fresh commit (projection
  # semantics: the forge copy mirrors priv exactly; template history is NOT load-bearing).
  # `main/` → the default branch (served by `generate`); `ops/` → the `ops`
  # branch (pure blueprint: `generate` ignores non-default branches — verified live — the
  # runtime writes this face itself via Scaffold.work, same source; raw ${VAR}s on the
  # forge are the honest blueprint, expansion happens at write time).
  @doc false
  def push_template(repo, fc) do
    # The token rides the git ENVIRON (extraheader via GIT_CONFIG_*), NEVER the argv/URL:
    # /proc/<pid>/cmdline is world-readable (another human's `ps` would read a token-in-URL), the
    # environ is owner-only. We reuse the runtime's SINGLE SOURCE (Fleet.Credentials.ForgeAuth) rather
    # than hand-composing the header — but `app.start` is skipped here (by design), so we set the same
    # :forge_auth config config/runtime.exs sets at boot, from the env this caller already read.
    base_prefix = String.trim_trailing(Keyword.fetch!(fc, :base_url), "/")

    Application.put_env(:lcars_fleet, :credentials_forge_auth, %{
      url_prefix: base_prefix,
      token: Keyword.fetch!(fc, :token)
    })

    # PLAIN url (no userinfo) — the auth is the env header, matched by git on the `url_prefix`.
    url = base_prefix <> "/" <> repo <> ".git"

    with {:ok, auth_env} <- Fleet.Credentials.ForgeAuth.git_env_result(),
         :ok <- push_face(url, auth_env, "main", "main") do
      push_face(url, auth_env, "ops", "ops")
    end
  end

  # Each face is its own throwaway git repo → the two pushed branches share no ancestor
  # (ops is orphan by construction, exactly like the runtime's add_work_ops). Force-push is the
  # projection semantic (overwrite the forge copy, never merge — L13); a lease would need a
  # remote-tracking ref this fresh `git init` never had, so the blind force is correct HERE.
  defp push_face(url, auth_env, face, branch) do
    src = Path.join(Fleet.Catalogue.project_template_root(), face)
    tmp = Path.join(System.tmp_dir!(), "lcars-tpl-#{face}-#{System.unique_integer([:positive])}")

    try do
      File.mkdir_p!(tmp)
      _ = File.cp_r!(src, tmp)

      # All ops via Fleet.Credentials.Shell.git: BOUNDED (a hung network push no longer suspends the
      # deploy forever) + hooks-off; the push carries the token through `env`, never the argv.
      with {:ok, {_, 0}} <-
             git(["init", "-q", "-b", branch], cd: tmp, timeout_ms: @local_timeout_ms),
           {:ok, {_, 0}} <- git(["add", "-A"], cd: tmp, timeout_ms: @local_timeout_ms),
           {:ok, {_, 0}} <-
             git(
               [
                 "-c",
                 "user.name=lcars-system",
                 "-c",
                 "user.email=lcars-system@lcars.local",
                 "commit",
                 "-q",
                 "-m",
                 "chore(template): sync #{face} face from the catalogue project_template"
               ],
               cd: tmp,
               timeout_ms: @local_timeout_ms
             ),
           {:ok, {_, 0}} <-
             git(["push", "-q", "--force", url, branch],
               cd: tmp,
               env: auth_env,
               timeout_ms: @push_timeout_ms
             ) do
        :ok
      else
        {:ok, {out, rc}} -> {:error, {:git, face, rc, out}}
        {:error, reason} -> {:error, {:git, face, reason}}
      end
    after
      _ = File.rm_rf(tmp)
    end
  end

  # Git runner seam (default = the bounded, hooks-off Fleet.Credentials.Shell.git). A test overrides it
  # to capture the exact argv and prove the forge token never rides it.
  defp git(args, opts) do
    runner =
      Application.get_env(:lcars_fleet, :template_sync_git_runner, &Fleet.Credentials.Shell.git/2)

    runner.(@hooks_off ++ args, opts)
  end
end
