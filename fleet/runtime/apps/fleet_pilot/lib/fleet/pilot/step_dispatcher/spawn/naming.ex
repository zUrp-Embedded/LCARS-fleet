defmodule Fleet.Pilot.StepDispatcher.Spawn.Naming do
  @moduledoc """
  Builders d'opts / naming du spawn, extraits de `StepDispatcher.Spawn` : tout ce qui
  NOMME ou RÉSOUT une donnée d'identité embarquée dans les `spawn_opts` (label RC
  Desktop, slug de branche, route gravée, repo_id forge). Quasi-purs (seule
  `resolve_repo_id/3` lit la forge), zéro décision de spawn — la feuille `Spawn` garde
  la MÉCANIQUE (ordre verrou→pod→enqueue→wake, compensation, sérialisation de scope).

  Partagés par les DEUX flux du dispatcher (issue via `StepDispatcher`, review via
  `ReviewLifecycle.RoleDispatch`) — une seule copie de chaque, jamais un fork.
  """

  @doc """
  Nom RC Desktop = `<projet>_<role>` (projet = segment final du repo, ex.
  `fleet/poc-8` → `poc-8`). Label EXACT (claude_launch → `--remote-control "<nom>"`, zéro suffixe
  auto). Distinct du pod_id (clé technique repo-scopée) ; ici c'est le label humain-lisible Desktop.
  """
  @spec rc_name(String.t(), String.t()) :: String.t()
  def rc_name(repo, role), do: "#{project_name(repo)}_#{role}"

  # Nom de projet path/name-safe (charset [A-Za-z0-9-], zéro espace/`/`/`_`).
  # Segment final du repo, sanitizé. C'est LA source du `<project>` partout en aval (nom RC Desktop,
  # SANDBOX_HOME `/home/<project>`, seed-store, branche) via `rc_name` → un seul point de vérité, propre.
  # Pas de `_` (séparateur de rc_name `<project>_<role>` → garderait l'ambiguïté).
  defp project_name(repo),
    do: repo |> String.split("/") |> List.last() |> String.replace(~r/[^A-Za-z0-9-]/, "-")

  @doc """
  Slug parlant du titre du issue pour la branche LOCALE (`feature/<slug>`).
  Sanitizé + tronqué ; vide → `work`. Aucune fuite de pod_id/human.
  """
  @spec feature_slug(map()) :: String.t()
  def feature_slug(issue) do
    (issue["title"] || "")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> String.slice(0, 40)
    |> case do
      "" -> "work"
      s -> s
    end
  end

  # (Les poses conditionnelles à UNE clé — `:project`, `:repo_id` — passent par la source unique
  # `Fleet.Pilot.Opts.maybe_put/3` aux sites d'appel : plus de wrapper à clé figée ici. Seule
  # `maybe_put_route/2` vit ici — elle pose DEUX clés couplées, ce n'est pas l'idiome maybe_put.)

  @doc "Pose `:workflow_map`/`:step` dans les spawn_opts si la route est présente (nil = no-op)."
  @spec maybe_put_route(keyword(), {String.t(), String.t()} | nil) :: keyword()
  def maybe_put_route(spawn_opts, nil), do: spawn_opts

  def maybe_put_route(spawn_opts, {workflow_map_name, step}),
    do: spawn_opts |> Keyword.put(:workflow_map, workflow_map_name) |> Keyword.put(:step, step)

  @doc """
  Résout le `repo_id` forge (borné à `<REPO4>` = `rem(id, 10000)`) — l'id forge du projet fait le
  session_id déterministe des rôles project-bound (eng, juges) via `Fleet.Spawner.SessionId`
  (segment `<REPO4>` DÉCIMAL). Forge sans `repo_id/2` (stub) / forge down / id absent → `nil`
  (pas de `:repo_id` posé — `Opts.maybe_put` avale le nil au site d'appel). Un rôle project-bound
  spawné SANS repo est alors une ANOMALIE : le mint (`Fleet.Spawner.Pod.SessionMint`) FAIL-LOUD (raise)
  — on ne fabrique JAMAIS un UUID random pour masquer une forge non résolue (forge = organe de
  LCARS, forge down = stop). `rem(id, 10000)` : `<REPO4>` = 4 chiffres décimaux → DETTE assumée,
  le repo 10000 collisionne le repo 0 (on ne rouvrira pas le vieux ; cf. SessionId moduledoc).
  """
  @spec resolve_repo_id(module(), String.t(), keyword()) :: non_neg_integer() | nil
  def resolve_repo_id(forge, repo, forge_opts) do
    if function_exported?(forge, :repo_id, 2) do
      case forge.repo_id(repo, forge_opts) do
        {:ok, id} when is_integer(id) and id >= 0 -> rem(id, 10000)
        _ -> nil
      end
    else
      nil
    end
  end
end
