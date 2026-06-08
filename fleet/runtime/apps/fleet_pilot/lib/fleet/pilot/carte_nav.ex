defmodule Fleet.Pilot.CarteNav do
  @moduledoc """
  Navigation **pure** dans une carte (pipeline) — le chaînage forge-driven d'A2
  (DN `orchestration/forge-state-machine.md` §8). Remplace la logique RAM
  `Executor.next_stage_or_done` par une résolution **stateless** : étant donné la
  carte (sortie `Fleet.Pipeline.Loader`) + le **nom du stage courant**, calcule le
  stage suivant (ou terminal).

  ## Pourquoi clé par NOM de stage, pas par rôle

  La DN §8 dit « le runtime trouve le stage dont `role` = assignee ». **Insuffisant** :
  une carte peut avoir le même rôle sur plusieurs stages (ex. `standard-qa` :
  `architect-interactive` est sur `brainstorm` ET `plan`). L'assignee (= rôle) seul
  **n'identifie pas** le stage. La position canonique est donc le **nom du stage**, que
  le runtime grave sur la forge (lock comment enrichi `[lock:role:stage:ts]`, cf.
  A2.4/A2.1) et relit pour naviguer. `CarteNav` est keyé par nom de stage ; d'où vient
  le nom (forge) est le concern de l'appelant.

  ## Cardinalité (MVP linéaire, DN §8)

  La chaîne MVP est **linéaire** : chaque stage a 0 ou 1 successeur (le stage qui le
  `needs`). Un DAG à branches parallèles (≥2 successeurs) est **hors-scope** (§13) →
  `{:error, :dag_not_supported}` explicite (pas de choix silencieux). Idem entrée :
  exactement 1 racine (`needs: []`).

  ## Format carte consommé

  Sortie `Loader` : `%{"name" => ..., "stages" => %{name => %{"role", "needs", "gate"?, ...}}}`.
  Clés string (le Loader normalise v1/v2.5 vers cette forme). `CarteNav` ne charge pas —
  l'appelant passe la carte déjà chargée.
  """

  @type carte :: %{required(String.t()) => any()}
  @type stage_name :: String.t()
  @type role :: String.t()

  @doc """
  Stage d'entrée = l'unique racine (`needs: []`). `{:error, :no_root}` si aucune,
  `{:error, :multiple_roots}` si ≥2 (entrée parallèle = hors-scope).
  """
  @spec first_stage(carte()) :: {:ok, {stage_name(), role()}} | {:error, atom()}
  def first_stage(carte) do
    stages = stages(carte)

    roots =
      Enum.filter(stages, fn {_name, spec} -> needs(spec) == [] end)

    case roots do
      [{name, spec}] -> {:ok, {name, role(spec)}}
      [] -> {:error, :no_root}
      _ -> {:error, :multiple_roots}
    end
  end

  @doc """
  Stage suivant le stage courant (par `needs`). `:terminal` si aucun successeur
  (fin de chaîne) ; `{:error, :unknown_stage}` si le stage courant n'existe pas ;
  `{:error, :dag_not_supported}` si ≥2 successeurs (branche parallèle, hors-scope §13).
  """
  @spec next_stage(carte(), stage_name()) ::
          {:ok, {stage_name(), role()}} | :terminal | {:error, atom()}
  def next_stage(carte, current_stage) when is_binary(current_stage) do
    stages = stages(carte)

    if not Map.has_key?(stages, current_stage) do
      {:error, :unknown_stage}
    else
      successors =
        Enum.filter(stages, fn {_name, spec} -> current_stage in needs(spec) end)

      case successors do
        [] -> :terminal
        [{name, spec}] -> {:ok, {name, role(spec)}}
        _ -> {:error, :dag_not_supported}
      end
    end
  end

  @doc "Rôle d'un stage nommé. `:error` si inconnu."
  @spec stage_role(carte(), stage_name()) :: {:ok, role()} | :error
  def stage_role(carte, stage_name) do
    case Map.get(stages(carte), stage_name) do
      nil -> :error
      spec -> {:ok, role(spec)}
    end
  end

  @doc "Spec brute d'un stage (pour lire `gate`, `profile`, `timeout_sec`…). `:error` si inconnu."
  @spec stage_spec(carte(), stage_name()) :: {:ok, map()} | :error
  def stage_spec(carte, stage_name) do
    case Map.get(stages(carte), stage_name) do
      nil -> :error
      spec -> {:ok, spec}
    end
  end

  # ── internals ──
  defp stages(carte), do: Map.get(carte, "stages", %{})
  defp needs(spec), do: Map.get(spec, "needs", [])
  defp role(spec), do: Map.get(spec, "role")
end
