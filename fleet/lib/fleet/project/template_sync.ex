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
  @spec standalone_sync(keyword(), String.t() | nil) ::
          {:ok, String.t()} | {:ok, :no_template} | {:error, term()}
  def standalone_sync(fc, catalogue \\ nil) do
    with {:ok, _} <- Application.ensure_all_started(:req),
         {:ok, _} <-
           Supervisor.start_link([Fleet.Forge.finch_spec()], strategy: :one_for_one) do
      sync(fc, catalogue)
    else
      {:error, reason} -> {:error, {:transport, reason}}
    end
  end

  @doc """
  Syncs the template repo of `catalogue` (`nil` = the bundled one). Requires `base_url:` and
  `token:`, and a transport already up.

  ## `{:ok, :no_template}` is a SUCCESS, and it is the common case

  A catalogue carrying no `project_template` tree has nothing to project, and that is legitimate:
  the template is the one tree allowed to fall back on the reference catalogue's, because it names
  nothing and is named by nothing. Returning an error there would make `catalogue install` report a
  failure for a catalogue that installed perfectly.

  What it must NOT do is push the BUNDLED tree into that catalogue's org: the forge would then
  carry a `<catalogue>/project-template` that `Onboard` resolves to — so the fallback would stop
  being visible, and a catalogue would silently serve a neighbour's material under its own name.
  The absence of the repo IS what makes the fallback observable.
  """
  @spec sync(keyword(), String.t() | nil) ::
          {:ok, String.t()} | {:ok, :no_template} | {:error, term()}
  def sync(fc, catalogue \\ nil) do
    root = catalogue_root(catalogue)
    src = Path.join(root, Fleet.Catalogue.rel(:project_template))

    if File.dir?(src) do
      repo = Fleet.Project.Onboard.project_template(org: catalogue)
      [org, name] = String.split(repo, "/", parts: 2)

      with :ok <- ensure_repo(org, name, repo, fc),
           :ok <- push_template(repo, src, fc),
           :ok <- Fleet.Forge.Client.Repo.set_template(repo, true, fc),
           :ok <- Fleet.Forge.Client.ensure_protocol_labels(repo, fc) do
        {:ok, repo}
      end
    else
      {:ok, :no_template}
    end
  end

  # `root_for/1` answers `nil` for a catalogue this box does not serve, and the bundled root is the
  # right answer then: the only caller passing a name is `catalogue install`, which has just laid
  # the material — if it is not there, the name is not one of ours and there is nothing of its own
  # to project.
  defp catalogue_root(nil), do: Fleet.Catalogue.root()

  defp catalogue_root(name) when is_binary(name),
    do: Fleet.Catalogue.root_for(name) || Fleet.Catalogue.root()

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
  # DEUX SPECS, parce qu'un defaut engendre DEUX fonctions. `eval_main/0` et `eval_main/1` sont
  # deux arites reelles pour Dialyzer, et n'en declarer qu'une laisse l'autre sans `no_return` —
  # donc signalee « n'a pas de retour local » alors que c'est exactement ce qu'elle promet.
  @spec eval_main() :: no_return()
  @spec eval_main(String.t() | nil) :: no_return()
  def eval_main(catalogue \\ nil) do
    case forge_opts_from_env() do
      {:ok, fc} ->
        case standalone_sync(fc, catalogue) do
          {:ok, :no_template} ->
            # SAID, and it exits 0. A catalogue with no template of its own is legitimate, but the
            # operator must be able to tell it apart from a sync that ran — otherwise the fallback
            # is discovered later, in the scaffold of a project nobody expected to look foreign.
            IO.puts(
              "project-template: #{catalogue || "(bundled)"} carries no project_template tree — " <>
                "its projects will be scaffolded from the reference catalogue's"
            )

            System.halt(0)

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
  def push_template(repo, src_root, fc) do
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
         :ok <- push_face(url, auth_env, src_root, "main", "main") do
      push_face(url, auth_env, src_root, "ops", "ops")
    end
  end

  # Each face is its own throwaway git repo → the two pushed branches share no ancestor
  # (ops is orphan by construction, exactly like the runtime's add_work_ops). Force-push is the
  # projection semantic (overwrite the forge copy, never merge — L13); a lease would need a
  # remote-tracking ref this fresh `git init` never had, so the blind force is correct HERE.
  defp push_face(url, auth_env, src_root, face, branch) do
    src = Path.join(src_root, face)
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
               # L'IDENTITE SYSTEME SE DEMANDE, ELLE NE SE RECOPIE PAS. `ForgeIdentity` porte
               # `ONE system identity, defined HERE only` — et trois fichiers en tenaient une copie
               # litterale, dont celui-ci. Le renommage du compte l'a revele : une autorite qui se
               # declare unique et qu'on recopie n'en est pas une, elle est juste la premiere a etre
               # corrigee le jour ou le nom bouge.
               [
                 "-c",
                 "user.name=#{Fleet.Credentials.ForgeIdentity.system_identity().name}",
                 "-c",
                 "user.email=#{Fleet.Credentials.ForgeIdentity.system_email()}",
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
