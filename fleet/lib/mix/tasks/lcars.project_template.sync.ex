defmodule Mix.Tasks.Lcars.ProjectTemplate.Sync do
  # Z4 — Mix task classified into the boundary of its subject (the onboarding forge surface).
  use Boundary, classify_to: Fleet.Pilot

  @shortdoc "Projects priv/catalogue/project_template onto the forge template repo (fleet/project-template)"

  @moduledoc """
  Force-projects the local project-template source onto its forge template repo,
  marks it native-template, and seeds protocol labels. It uses explicit environment
  credentials and never starts a second fleet.
  """

  use Mix.Task

  # Every git op runs on the WORLD side (outside any sandbox) — compose the runtime's SINGLE-SOURCE
  # config neutralization (hooks/fsmonitor/sshCommand/diff.external) so a `.gitattributes`/config
  # shipped in the template tree cannot execute code here. Same invariant as Fleet.Workflow.Git.
  @hooks_off Fleet.Credentials.Shell.git_safe_config_args()

  # WALL bounds (setsid + SIGKILL of the OS process-group at the deadline, via Shell.git). Local ops
  # are sub-second; the NETWORK push is the one that could hang a deploy forever without a bound.
  @local_timeout_ms 30_000
  @push_timeout_ms 60_000

  @impl true
  def run(_args) do
    Mix.Task.run("loadpaths")
    {:ok, _} = Application.ensure_all_started(:req)
    # The ForgeClient transport rides the app-supervised Finch pool — absent here (no
    # app.start, by design): start the SAME child spec under a task-local supervisor.
    {:ok, _} =
      Supervisor.start_link([Fleet.Pilot.Application.forge_finch_spec()], strategy: :one_for_one)

    fc = forge_opts!()
    repo = Fleet.Project.Onboard.project_template()
    [org, name] = String.split(repo, "/", parts: 2)

    with :ok <- ensure_repo(org, name, repo, fc),
         :ok <- push_template(repo, fc),
         :ok <- Fleet.Forge.Client.Repo.set_template(repo, true, fc),
         :ok <- Fleet.Forge.Client.ensure_protocol_labels(repo, fc) do
      Mix.shell().info("project-template: #{repo} synced (content + template flag + labels)")
    else
      {:error, reason} -> Mix.raise("project-template sync FAILED: #{inspect(reason)}")
    end
  end

  defp forge_opts!() do
    base =
      System.get_env("FORGE_BASE_URL") ||
        Mix.raise("FORGE_BASE_URL missing (source ~/.lcars/fleet_v2.env)")

    token_file =
      System.get_env("FORGE_TOKEN_FILE") ||
        Mix.raise("FORGE_TOKEN_FILE missing (source ~/.lcars/fleet_v2.env)")

    [base_url: base, token: token_file |> File.read!() |> String.trim()]
  end

  defp ensure_repo(org, name, repo, fc) do
    case Fleet.Forge.Client.Repo.create_repo(
           name,
           Keyword.merge(fc,
             org: org,
             description: "Modèle de projet fleet — généré par mix lcars.project_template.sync",
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
    # :forge_auth config config/runtime.exs sets at boot, from the env this task already read.
    base_prefix = String.trim_trailing(Keyword.fetch!(fc, :base_url), "/")

    Application.put_env(:fleet_credentials, :forge_auth, %{
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
                 "chore(template): sync #{face} face from priv/catalogue/project_template"
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
