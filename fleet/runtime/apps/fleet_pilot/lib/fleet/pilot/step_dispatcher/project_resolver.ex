defmodule Fleet.Pilot.StepDispatcher.ProjectResolver do
  @moduledoc """
  Résolution projet : pinning de la base git (`base_sha` / `gate_base_sha`) via `git ls-remote`,
  HORS-POD. Cluster I/O ISOLÉ extrait de `Fleet.Pilot.StepDispatcher`.

  Frontière **quasi-pure** : ce module ne touche AUCUN seam module (pas de forge_client / spawner /
  task_queue / loader) ; il lit `opts` / `forge_opts` et appelle `Fleet.Credentials.Shell` /
  `Fleet.Credentials.ForgeAuth` (auth runtime, jamais le pod — le pod est forge-aveugle).

  `default_project_resolver/2` est l'API PUBLIQUE : c'est le défaut du seam `:project_resolver` de
  `StepDispatcher` (délégué depuis le module racine via `defdelegate`) ET la fn appelée directement par
  les tests. Le reste (résolution gate-base, base_url, ls-remote) est interne à ce cluster.
  """

  # Construit `%{repo_path, base_branch, base_sha}` pour le repo du issue.
  # `base_url` ← `:forge_opts[:base_url]` ou config app ; `base_branch` ← `:base_branch`
  # (défaut "main"). Pas de forge configurée → `{:ok, nil}` (pod sans repo, ex. tests
  # locaux). L'auth de clone/ls-remote est portée par le runtime (`Fleet.Credentials.ForgeAuth.
  # git_env`, token via env), jamais par le pod (forge-aveugle).
  @spec default_project_resolver(String.t(), keyword()) ::
          {:ok, map() | nil} | {:error, term()}
  def default_project_resolver(repo, opts) do
    forge_opts = Keyword.get(opts, :forge_opts, [])
    base_branch = Keyword.get(opts, :base_branch, "main")

    # DÉCONFLATION clone-base / gate-base. `base_sha` confondrait sinon deux
    # concerns : (1) le POINT DE DÉPART du clone (`pin_base_sha` reset HEAD dessus) et (2) la
    # base de la GATE (HEAD doit en DESCENDRE). Forward (build/rework) : ils coïncident. RÉSOLUTION
    # par rebase : ils DIVERGENT — le pod part de la feature (son travail) mais doit descendre de `main`.
    # `:gate_base_branch` (posé par le dispatch resolve) pinne la base de gate séparément ; absent → la
    # gate retombe sur la clone-base (`base_sha`), comportement forward INCHANGÉ.
    gate_base_branch = Keyword.get(opts, :gate_base_branch)

    case forge_base_url(forge_opts) do
      nil ->
        {:ok, nil}

      base_url ->
        repo_url = "#{String.trim_trailing(base_url, "/")}/#{repo}.git"

        with {:ok, sha} <- ls_remote_sha(repo_url, base_branch),
             {:ok, gate_sha} <- resolve_gate_base_sha(repo_url, gate_base_branch, sha) do
          # `"repo"` (full_name "owner/name") embarqué dans le projet → il voyage jusqu'au pod
          # puis ressort dans `pod.completed` (`CompletedPayload.build`) → le StepRunConsumer sait sur QUEL
          # repo agir (multi-projet), sans le re-dériver. `repo_path` = l'URL de push (remote per-step-run).
          {:ok,
           %{
             "repo" => repo,
             "repo_path" => repo_url,
             "base_branch" => base_branch,
             "base_sha" => sha,
             # gate_base_sha = base de la GATE (≠ clone-base pour une résolution rebase, cf. supra).
             "gate_base_sha" => gate_sha
           }}
        end
    end
  end

  # Base de la GATE. Défaut (forward) : = clone-base (`base_sha`) → la garde exige que HEAD descende
  # de là où le pod a cloné. Un dispatch resolve passe `:gate_base_branch` ("main") → on pinne le tip de
  # CETTE branche (la cible du rebase) : la garde exige alors que HEAD descende de `main`, pas de l'ancien
  # tip de feature (réécrit par le rebase → il ne serait plus ancêtre, d'où un `base_not_ancestor`).
  defp resolve_gate_base_sha(_repo_url, nil, clone_base_sha), do: {:ok, clone_base_sha}

  defp resolve_gate_base_sha(repo_url, branch, _clone_base_sha) when is_binary(branch),
    do: ls_remote_sha(repo_url, branch)

  defp forge_base_url(forge_opts) do
    Keyword.get(forge_opts, :base_url) ||
      get_in(Application.get_env(:fleet_pilot, :forge, []), [:base_url])
  end

  # `git ls-remote <repo_url> <branch>` borné via `Fleet.Credentials.Shell` (source unique de la borne)
  # + auth runtime → SHA du tip (hors-pod). Symétrique du pin de base côté pipeline. Le wrapper lance le
  # ls-remote (RÉSEAU : peut hung/prompter) dans son propre process-group et, à la deadline MUR, tue le
  # GROUPE entier (le ls-remote ET ses helpers de transport, porteurs du token forge) + ferme le port —
  # là où le patron `Task.async` + `shutdown(:brutal_kill)` ne tuait que le Task BEAM en laissant fuir le
  # process git.
  defp ls_remote_sha(repo_url, branch) do
    # Token forge via env (hors argv/cmdline) — source unique Fleet.Credentials.ForgeAuth.
    case Fleet.Credentials.Shell.git(["ls-remote", repo_url, branch],
           timeout_ms: 15_000,
           env: Fleet.Credentials.ForgeAuth.git_env()
         ) do
      {:ok, {out, 0}} ->
        case out |> String.split("\n", trim: true) |> List.first() do
          nil -> {:error, :no_ref}
          line -> {:ok, line |> String.split() |> List.first()}
        end

      {:ok, {out, rc}} ->
        {:error, {rc, String.trim(out)}}

      {:error, {:timeout, _ms}} ->
        {:error, :timeout}

      {:error, {:exit, reason}} ->
        {:error, {:exit, reason}}
    end
  end
end
