defmodule Fleet.Pilot.PodId do
  @moduledoc """
  ID de pod sémantique DÉTERMINISTE, **repo-scopé**.

  Le pod_id est la clé GLOBALE du pod : `Registry`, broker `task.pod_id`, `pod_dir`
  (`~/pods/pod_<id>`), sock, et nom de session tmux (`lcars-pod-<id>`). Sans repo-scope,
  `issue-N-role` collisionne entre repos/runs au même n° → un SEUL pod pour deux travaux
  distincts (multi-repo / délégation cross-repo). Le slug repo désambiguïse.

  DÉTERMINISTE (clé stable, sans suffixe timestamp) : même `(repo, n, role)` → même id → un re-dispatch retombe sur
  le pod vivant pour le RE-MANDATER (garde son contexte). Jamais re-parsé → **opaque** après
  construction (le séparateur n'a pas à être réversible) ; seule exigence : TOUS les sites
  construisent via ces fonctions (un format unique, pas de littéral dupliqué).

  La feature-branch (`lcars/issue-N-role`) reste **repo-LOCALE** (elle vit DANS le repo → pas de
  collision) → NON scopée. pod_id et branche sont construits indépendamment depuis `(n, role)`.

  Path-safe (charset `[A-Za-z0-9._-]`) car interpolé dans des paths FS / noms tmux.
  """

  @doc "pod_id producteur (keyé ISSUE) : `<repo-slug>-issue-<n>-<role>`."
  @spec for_issue(String.t(), integer() | String.t(), String.t()) :: String.t()
  def for_issue(repo, n, role), do: "#{slug(repo)}-issue-#{n}-#{role}"

  @doc "pod_id juge (keyé PR) : `<repo-slug>-pr-<n>-<role>`."
  @spec for_pr(String.t(), integer() | String.t(), String.t()) :: String.t()
  def for_pr(repo, n, role), do: "#{slug(repo)}-pr-#{n}-#{role}"

  @doc """
  pod_id PROJET (keyé repo SEUL, sans numéro) : `<repo-slug>-<role>`. Pour les rôles `slot_scope:
  project` (engineer, singletons fleet-level) : UNE identité par (repo, rôle) → un re-dispatch de
  N'IMPORTE quelle issue/PR du repo retombe sur le MÊME pod_id → UN slot Desktop stable (cwd +
  session-id figés), dispatch sérialisé par (repo, rôle). À opposer à `for_issue`/`for_pr` (keyés par
  instance → fan-out). Réutilise `scope_prefix/1` (source unique du slug). Le rôle (`engineer`, …) ne
  contient jamais `-issue-`/`-pr-` → pas de collision avec un id d'instance.
  """
  @spec for_repo(String.t(), String.t()) :: String.t()
  def for_repo(repo, role) when is_binary(role), do: scope_prefix(repo) <> role

  @doc """
  Préfixe de scope REPO d'un pod_id : `<repo-slug>-`. C'est l'ANCRE qui qualifie une clé de
  verrou par repo. Tout pod_id du repo commence par lui (`for_issue`/`for_pr` posent `<slug>-issue|pr-…`).
  Source UNIQUE du slug (le même que `for_issue`/`for_pr`) → la réconciliation scope ses refs par repo
  sans re-dériver le format. (`PodId` reste opaque : on ne re-parse pas l'id, on l'ANCRE par préfixe.)
  """
  @spec scope_prefix(String.t()) :: String.t()
  def scope_prefix(repo) when is_binary(repo), do: "#{slug(repo)}-"

  # `owner/name` → `owner-name` ; tout char hors-charset path-safe → `-`.
  defp slug(repo) when is_binary(repo) do
    repo
    |> String.replace("/", "-")
    |> String.replace(~r/[^A-Za-z0-9._-]/, "-")
  end
end
