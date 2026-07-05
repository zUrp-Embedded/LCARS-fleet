defmodule Fleet.MCP.PodTools.Delegation.ProjectOnboard do
  @moduledoc """
  Behaviour de la séquence d'onboarding projet — le CONTRAT du seam runtime
  `:project_onboard`, consommé par `Fleet.MCP.PodTools.Delegation`
  (canal ONBOARDING, tool `create_project`).

  ## Pourquoi un seam RUNTIME (et pas une dep compile)

  `fleet_mcp` est Ring 2, `fleet_pilot` est Ring 3 (au-dessus) : une dep mix.exs
  `fleet_mcp → fleet_pilot` serait MONTANTE, interdite. Le module est résolu au
  RUNTIME (`resolved/0` : app-env + défaut en atom littéral → aucune dep
  compile-time, aucun cycle). Seam déclaré dans
  `fleet_event_router/priv/allowed_graph.yaml` (section `seams`, direction `up`).

  ## Implémentations

    * `Fleet.Pilot.ProjectOnboard` — impl RÉELLE (défaut canon : repo forge +
      dual-worktree `main`/`work/ops` + scaffold + push). Elle vit dans
      `fleet_pilot`, qui ne dépend PAS de `fleet_mcp` : elle ne PEUT PAS adopter ce
      behaviour et reste DUCK-TYPÉE avec un commentaire croisé ; le type du
      callback est aligné sur son `@spec onboard/2` (`result()`).
    * Stub test `Fleet.MCP.PodToolsTest.StubOnboard` — même app → adopte le
      behaviour (le compilateur vérifie la conformité).
  """

  @doc """
  Onboard le projet `name` (slug kebab-case). `opts` consommés par le défaut réel :
  `:org`, `:description`, `:pitch` (cf. `Fleet.Pilot.ProjectOnboard.onboard/2`).
  Le résultat DOIT porter les 3 clés — `Delegation.do_create_project/2` pattern-matche
  `%{repo: _, project_dir: _, work_dir: _}` strictement.
  """
  @callback onboard(name :: String.t(), opts :: keyword()) ::
              {:ok, %{repo: String.t(), project_dir: Path.t(), work_dir: Path.t()}}
              | {:error, term()}

  # Défaut canon : la séquence d'onboarding réelle côté fleet_pilot. Atom littéral
  # (pas d'appel remote littéral) → aucune dep compile-time. Posé ICI une seule fois.
  @default_onboard Fleet.Pilot.ProjectOnboard

  @doc """
  Séquence d'onboarding résolue : config `:fleet_mcp, :project_onboard` sinon le
  défaut canon `Fleet.Pilot.ProjectOnboard`. SOURCE UNIQUE du défaut.
  """
  @spec resolved() :: module()
  def resolved, do: Application.get_env(:fleet_mcp, :project_onboard, @default_onboard)
end
