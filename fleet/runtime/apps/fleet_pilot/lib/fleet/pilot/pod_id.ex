defmodule Fleet.Pilot.PodId do
  @moduledoc """
  ID de pod sémantique DÉTERMINISTE, **repo-scopé**.

  Le pod_id est la clé GLOBALE du pod : `Registry`, broker `task.pod_id`, `pod_dir`
  (`~/pods/pod_<id>`), sock, et nom de session tmux (`lcars-pod-<id>`). Sans repo-scope,
  `issue-N-role` collisionne entre repos/runs au même n° → un SEUL pod pour deux travaux
  distincts (multi-repo / délégation cross-repo). Le slug repo désambiguïse.

  DÉTERMINISTE (clé stable, sans suffixe timestamp) : même `(repo, n, role)` → même id → un re-dispatch retombe sur
  le pod vivant pour le RE-MANDATER (garde son contexte). Le format vit ENTIEREMENT ici : `for_issue`/`for_pr`
  le CONSTRUISENT, `parse_ref/2` l'ANCRE (phase + numero d'instance) pour la reconciliation de verrous. Un seul
  module connait le format -> aucun parseur distant ne le re-derive (un changement de format ne casse personne
  en silence). On ne reconstruit jamais `(n, role)` complets depuis l'id (le role n'est pas re-extrait) : l'id
  reste opaque a l'exterieur, qui passe par `parse_ref/2` plutot que de re-parser le litteral.

  La feature-branch (`lcars/issue-N-role`) reste **repo-LOCALE** (elle vit DANS le repo → pas de
  collision) → NON scopée. pod_id et branche sont construits indépendamment depuis `(n, role)`.

  Path-safe (contrat `Fleet.Spawner.valid_pod_id?/1`) car interpolé dans des paths FS / noms tmux.
  """

  # Marqueurs de phase d'instance — LITTERAL-SOURCE unique : `for_issue`/`for_pr` les POSENT,
  # `parse_ref` les RECONNAIT. Renommer = ce seul point (plus de token tape en double builder/parseur).
  # Alphanumeriques purs -> pas de Regex.escape necessaire cote parseur.
  @phase_issue "issue"
  @phase_pr "pr"

  @doc "pod_id producteur (keyé ISSUE) : `<repo-slug>-issue-<n>-<role>`."
  @spec for_issue(String.t(), integer() | String.t(), String.t()) :: String.t()
  def for_issue(repo, n, role),
    do: Enum.join([slug(repo), @phase_issue, component(n), component(role)], "-")

  @doc "pod_id juge (keyé PR) : `<repo-slug>-pr-<n>-<role>`."
  @spec for_pr(String.t(), integer() | String.t(), String.t()) :: String.t()
  def for_pr(repo, n, role),
    do: Enum.join([slug(repo), @phase_pr, component(n), component(role)], "-")

  @doc """
  pod_id PROJET (keyé repo SEUL, sans numéro) : `<repo-slug>-<role>`. Pour les rôles `slot_scope:
  project` (engineer, singletons fleet-level) : UNE identité par (repo, rôle) → un re-dispatch de
  N'IMPORTE quelle issue/PR du repo retombe sur le MÊME pod_id → UN slot Desktop stable (cwd +
  session-id figés), dispatch sérialisé par (repo, rôle). À opposer à `for_issue`/`for_pr` (keyés par
  instance → fan-out). Réutilise `scope_prefix/1` (source unique du slug). Le rôle (`engineer`, …) ne
  contient jamais `-issue-`/`-pr-` → pas de collision avec un id d'instance.
  """
  @spec for_repo(String.t(), String.t()) :: String.t()
  def for_repo(repo, role) when is_binary(role), do: scope_prefix(repo) <> component(role)

  @doc """
  Préfixe de scope REPO d'un pod_id : `<repo-slug>-`. C'est l'ANCRE qui qualifie une clé de
  verrou par repo. Tout pod_id du repo commence par lui (`for_issue`/`for_pr` posent `<slug>-issue|pr-…`).
  Source UNIQUE du slug (le même que `for_issue`/`for_pr`) → la réconciliation scope ses refs par repo
  sans re-dériver le format. (`PodId` reste opaque : on ne re-parse pas l'id, on l'ANCRE par préfixe.)
  """
  @spec scope_prefix(String.t()) :: String.t()
  def scope_prefix(repo) when is_binary(repo), do: "#{slug(repo)}-"

  @doc """
  Reconnait le marqueur d'INSTANCE qu'un pod_id encode (`issue`/`pr` + numero), ancre sur le scope du
  repo. Inverse partiel de `for_issue`/`for_pr` : l'autorite qui CONSTRUIT le format le RECONNAIT aussi,
  pour qu'aucun parseur distant n'ait a re-deriver le litteral (un changement de format casserait sinon
  un lecteur lointain en silence). On n'extrait QUE la phase et le numero (jamais le role) -> l'id reste
  opaque sur sa semantique complete.

  `{:ok, {:issue | :pr, n}}` si `pod_id` appartient au repo et encode une instance ;
  `:error` sinon (autre repo, ou pod_id projet `<repo>-<role>` sans `-issue|pr-N-`).
  """
  @spec parse_ref(String.t(), String.t()) :: {:ok, {:issue | :pr, pos_integer()}} | :error
  def parse_ref(pod_id, repo) when is_binary(pod_id) and is_binary(repo) do
    prefix = Regex.escape(scope_prefix(repo))

    case Regex.run(~r/^#{prefix}(#{@phase_issue}|#{@phase_pr})-(\d+)-/, pod_id) do
      [_, @phase_issue, n] -> {:ok, {:issue, String.to_integer(n)}}
      [_, @phase_pr, n] -> {:ok, {:pr, String.to_integer(n)}}
      _ -> :error
    end
  end

  def parse_ref(_, _), do: :error

  # `owner/name` → `owner-name` ; tout char hors-charset path-safe → `-`.
  # Les runs de `.` sont réduits pour satisfaire le contrat spawner (`..` interdit
  # même si le charset l'autorise).
  #
  # DOMAINE SLUG DISTINCT (ne pas fusionner) : `component` TRANSFORME vers le charset pod_id
  # `[A-Za-z0-9._-]` (casse + `.` preserves, contrat `valid_pod_id?`). Ce n'est NI `Fleet.Slug`
  # (VALIDE/rejette, minuscules strict, sans `.`), NI `SeedStore.slugify` (compat vendor Claude).
  defp slug(repo) when is_binary(repo) do
    repo
    |> String.replace("/", "-")
    |> component()
  end

  defp component(n) when is_integer(n), do: Integer.to_string(n)

  defp component(value) when is_binary(value) do
    value
    |> String.replace(~r/[^A-Za-z0-9._-]/, "-")
    |> String.replace(~r/\.{2,}/, ".")
  end
end
