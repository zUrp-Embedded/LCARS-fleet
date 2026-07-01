defmodule Fleet.Pilot.CarteNav do
  @moduledoc """
  Navigation **pure** dans une carte (pipeline) — le chaînage forge-driven des steps.
  Remplace la logique RAM `Executor.next_step_or_done` par une résolution
  **stateless** : étant donné la
  carte (sortie `Fleet.Pipeline.Loader`) + le **nom du step courant**, calcule le
  step suivant (ou terminal).

  ## Pourquoi clé par NOM de step, pas par rôle

  Clé naïve « le step dont `role` = assignee » : **insuffisant** —
  une carte peut avoir le même rôle sur plusieurs steps (ex. `standard-qa` :
  `architect` est sur `brainstorm` ET `plan`). L'assignee (= rôle) seul
  **n'identifie pas** le step. La position canonique est donc le **nom du step**, que
  le runtime grave sur la forge (lock comment enrichi `[lock:role:step:ts]`) et
  relit pour naviguer. `CarteNav` est keyé par nom de step ; d'où vient
  le nom (forge) est le concern de l'appelant.

  ## Cardinalité (MVP linéaire)

  La chaîne MVP est **linéaire** : chaque step a 0 ou 1 successeur (le step qui le
  `needs`). Un DAG à branches parallèles (≥2 successeurs) est **hors-scope** →
  `{:error, :dag_not_supported}` explicite (pas de choix silencieux). Idem entrée :
  exactement 1 racine (`needs: []`).

  ## Format carte consommé

  Sortie `Loader` : `%{"name" => ..., "steps" => %{name => %{"role", "needs", "gate"?, ...}}}`.
  Clés string (le Loader normalise v1/v2.5 vers cette forme). `CarteNav` ne charge pas —
  l'appelant passe la carte déjà chargée.
  """

  @type carte :: %{required(String.t()) => any()}
  @type step_name :: String.t()
  @type role :: String.t()

  @doc """
  Step d'entrée = l'unique racine (`needs: []`). `{:error, :no_root}` si aucune,
  `{:error, :multiple_roots}` si ≥2 (entrée parallèle = hors-scope).
  """
  @spec first_step(carte()) :: {:ok, {step_name(), role()}} | {:error, atom()}
  def first_step(carte) do
    steps = steps(carte)

    roots =
      Enum.filter(steps, fn {_name, spec} -> needs(spec) == [] end)

    case roots do
      [{name, spec}] -> {:ok, {name, role(spec)}}
      [] -> {:error, :no_root}
      _ -> {:error, :multiple_roots}
    end
  end

  @doc """
  Step suivant le step courant (par `needs`). `:terminal` si aucun successeur
  (fin de chaîne) ; `{:error, :unknown_step}` si le step courant n'existe pas ;
  `{:error, :dag_not_supported}` si ≥2 successeurs (branche parallèle, hors-scope).
  """
  @spec next_step(carte(), step_name()) ::
          {:ok, {step_name(), role()}} | :terminal | {:error, atom()}
  def next_step(carte, current_step) when is_binary(current_step) do
    steps = steps(carte)

    if not Map.has_key?(steps, current_step) do
      {:error, :unknown_step}
    else
      successors =
        Enum.filter(steps, fn {_name, spec} -> current_step in needs(spec) end)

      case successors do
        [] -> :terminal
        [{name, spec}] -> {:ok, {name, role(spec)}}
        _ -> {:error, :dag_not_supported}
      end
    end
  end

  @doc "Rôle d'un step nommé. `:error` si inconnu."
  @spec step_role(carte(), step_name()) :: {:ok, role()} | :error
  def step_role(carte, step_name) do
    case Map.get(steps(carte), step_name) do
      nil -> :error
      spec -> {:ok, role(spec)}
    end
  end

  @doc "Spec brute d'un step (pour lire `gate`, `profile`, `timeout_sec`…). `:error` si inconnu."
  @spec step_spec(carte(), step_name()) :: {:ok, map()} | :error
  def step_spec(carte, step_name) do
    case Map.get(steps(carte), step_name) do
      nil -> :error
      spec -> {:ok, spec}
    end
  end

  # Pas de garde-fou « explicit-step » (biconditionnelle soft⟺gatekeeper) : une gate `soft`
  # sur un step métier est légitime — elle dispatche le gatekeeper (juge d'exception), elle ne
  # désigne PAS un step `role: gatekeeper`. Il n'existe pas de step gatekeeper, donc rien à
  # valider. cf. `StepRunConsumer.gate_decide`.

  # ── internals ──
  defp steps(carte), do: Map.get(carte, "steps", %{})
  defp needs(spec), do: Map.get(spec, "needs", [])
  defp role(spec), do: Map.get(spec, "role")
end
