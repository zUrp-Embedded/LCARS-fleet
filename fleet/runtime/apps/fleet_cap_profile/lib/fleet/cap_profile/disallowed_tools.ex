defmodule Fleet.CapProfile.DisallowedTools do
  @moduledoc """
  Résolution write-time de la liste effective `disallowedTools` d'un pod :
  baseline git-denied universel ∪ patterns du cap-profile worker.

  Cluster extrait de `Fleet.CapProfile`. Concern UNIQUE : `spec.scope.disallowedTools`
  (écrit) + `spec.scope.git_ops_denied` (lu en entrée). Ne lit/écrit AUCUNE autre
  face du profil.

  Sens de dépendance UNIQUE (pas de cycle) : ce module dépend du struct
  `%Fleet.CapProfile{}` (compile-dep) ; `Fleet.CapProfile` appelle ce module via
  trois délégateurs — `with_resolved_disallowed_tools/1` (consommé par
  `Fleet.Spawner.Pod.do_allocate/1`), `git_ops_denied_patterns/1`,
  `baseline_git_ops_denied_patterns/0` (runtime-dep). L'API publique
  `Fleet.CapProfile.*` ne bouge pas. N'appelle NI `Schema` NI `Invariants` NI le
  cœur `load`/`compose`.

  I/O : lit le baseline priv IMMUABLE `priv/canon/cap-profiles/_baseline-git-denied.yaml`
  (résolu via `:code.priv_dir(:fleet_cap_profile)` — même fichier qu'avant
  l'extraction), read+parse caché une fois en `:persistent_term` (lazy-init ;
  erreurs non-cachées — le bang re-raise au prochain appel).
  """

  # Struct source (compile-dep) : les fns pattern-matchent `%CapProfile{}` et le
  # `@spec` référence `CapProfile.t()`. Pas de cycle (cf. moduledoc).
  alias Fleet.CapProfile

  @doc """
  Traduit les entrées sémantiques `spec.scope.git_ops_denied` (ex. `"push --force"`,
  `"reset --hard"`) en patterns `disallowedTools` claude CLI de la forme
  `Bash(git <entrée>:*)`. Les entrées vides/non-binaires sont ignorées. Ordre d'entrée
  préservé. Pure.

  Mécanisme générique catalogue → claude CLI : ce qui était une ligne déclarative
  validée G24 isolément devient une contrainte effectivement enforced par claude
  CLI au lancement du pod (disallow l'emporte sur allow sur le même pattern).
  """
  @spec git_ops_denied_patterns(CapProfile.t()) :: [String.t()]
  def git_ops_denied_patterns(%CapProfile{spec: spec}) do
    spec
    |> get_in(["scope", "git_ops_denied"])
    |> List.wrap()
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.map(&"Bash(git #{&1}:*)")
  end

  @doc """
  Retourne un `%CapProfile{}` dont `spec.scope.disallowedTools` est augmenté :
  - des patterns du **baseline universel** (`_baseline-git-denied.yaml`,
    intangibles selon principe directeur)
  - PUIS des patterns issus de `git_ops_denied_patterns/1` (cap-profile worker
    spécifique).
  Union dédupliquée, ordre préservé : existants, baseline, profile.
  Idempotent.

  Point d'application : `Fleet.Spawner.Pod.do_allocate/1` au moment d'écrire
  `.cap-profile.json` dans le pod, pour que `claude_launch.sh` reçoive la
  liste déjà résolue. Exposé sous `Fleet.CapProfile.with_resolved_disallowed_tools/1`
  (délégateur — c'est ce nom-là que consomme le spawner).
  """
  @spec with_resolved(CapProfile.t()) :: CapProfile.t()
  def with_resolved(%CapProfile{spec: spec} = profile) do
    baseline = baseline_patterns()
    profile_patterns = git_ops_denied_patterns(profile)
    existing = get_in(spec, ["scope", "disallowedTools"]) || []
    augmented = Enum.uniq(existing ++ baseline ++ profile_patterns)

    new_scope =
      spec
      |> Map.get("scope", %{})
      |> Map.put("disallowedTools", augmented)

    %{profile | spec: Map.put(spec, "scope", new_scope)}
  end

  @doc """
  Patterns `disallowedTools` issus du baseline universel
  (`priv/canon/cap-profiles/_baseline-git-denied.yaml`). Patterns
  intangibles refusés à TOUS les workers indépendamment du cap-profile —
  retirer un pattern = décision archi explicite (édit du fichier baseline,
  pas option de cap-profile).

  **Raise** si le fichier baseline est absent, illisible, ou de format
  invalide. La baseline est doctrinalement "intangible" : un fail-open
  silencieux (retour `[]`) désactiverait la denylist universelle sans
  alerter, contradictoire avec l'intention → fail-closed. Le caller
  (`pod.ex do_allocate`) catch via `rescue` et transitionne `:failed`
  proprement.

  Pure modulo I/O fichier ; read+parse caché en `:persistent_term`.
  """
  @spec baseline_patterns() :: [String.t()]
  def baseline_patterns do
    load_baseline_git_ops_denied!()
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.map(&"Bash(git #{&1}:*)")
  end

  # Baseline priv IMMUABLE : read+parse une fois, caché en `:persistent_term`
  # (lazy-init ; une erreur n'est pas cachée — le bang re-raise au prochain appel).
  # Copie locale ASSUMÉE du squelette `Fleet.SchemaCache.cached/2` (fleet_event_router —
  # l'autorité Ring 0 du chargé-caché, dédup B-R2) : fleet_cap_profile est Ring 0 SANS dep
  # vers fleet_event_router, on n'ajoute pas une arête intra-R0 (allowed_graph.yaml) pour
  # dix lignes. Si l'arête apparaît un jour pour une autre raison, migrer ce site
  # (et `CapProfile.Schema`).
  defp load_baseline_git_ops_denied! do
    key = {__MODULE__, :baseline_git_ops_denied}

    case :persistent_term.get(key, :miss) do
      :miss ->
        entries = read_baseline_git_ops_denied!()
        :persistent_term.put(key, entries)
        entries

      entries ->
        entries
    end
  end

  defp read_baseline_git_ops_denied! do
    path =
      :fleet_cap_profile
      |> :code.priv_dir()
      |> to_string()
      |> Path.join("canon/cap-profiles/_baseline-git-denied.yaml")

    case YamlElixir.read_from_file(path) do
      {:ok, %{"git_ops_denied" => entries}} when is_list(entries) ->
        entries

      {:ok, _other} ->
        raise "fleet_cap_profile baseline #{path} : clé `git_ops_denied` absente ou format invalide (baseline intangible — fail-closed)"

      {:error, reason} ->
        raise "fleet_cap_profile baseline #{path} absent ou corrompu (#{inspect(reason)}) (baseline intangible — fail-closed)"
    end
  end
end
