defmodule Fleet.MCP.PodTools.Delegation.ForgeClient do
  @moduledoc """
  Behaviour du client forge — le CONTRAT du seam runtime `:forge_client`, consommé
  par `Fleet.MCP.PodTools.Delegation` (canaux DÉLÉGATION / SUIVI).

  Le contrat appartient au CONSOMMATEUR : les callbacks sont EXACTEMENT les
  fonctions que `Delegation` appelle (create_issue, add_label, get_issue,
  list_open_pulls, parse_feature_branch, pr_review_verdicts) — pas la surface
  complète du client forge du pilot.

  ## Pourquoi un seam RUNTIME (et pas une dep compile)

  `fleet_mcp` est Ring 2, `fleet_pilot` est Ring 3 (au-dessus) : une dep mix.exs
  `fleet_mcp → fleet_pilot` serait MONTANTE, interdite. Le module est résolu au
  RUNTIME (`resolved/0` : app-env + défaut en atom littéral → aucune dep
  compile-time, aucun cycle). Seam déclaré dans
  `fleet_event_router/priv/allowed_graph.yaml` (section `seams`, direction `up`).

  ## Implémentations

    * `Fleet.Pilot.ForgeClient` — impl RÉELLE (défaut canon). Elle vit dans
      `fleet_pilot`, qui ne dépend PAS de `fleet_mcp` : elle ne PEUT PAS adopter
      ce behaviour (`@behaviour` = référence compile, créerait une arête nouvelle)
      et reste DUCK-TYPÉE avec un commentaire croisé. Ce module-ci est la source
      de vérité du contrat vu du consommateur ; les types des callbacks sont
      alignés sur les `@spec` réelles du pilot (`ForgeClient`, `ForgeClient.Jury`,
      `ForgeProtocol`).
    * Stubs test `Fleet.MCP.PodToolsTest.{StubForge, RecordingForge}` — même app →
      adoptent le behaviour (le compilateur vérifie la conformité, anti stub-menteur).
  """

  @doc "Pose une issue → `{:ok, numéro}` (auteur/assignee/token passés en `opts`)."
  @callback create_issue(
              repo :: String.t(),
              title :: String.t(),
              body :: String.t(),
              opts :: keyword()
            ) :: {:ok, issue_number :: integer()} | {:error, term()}

  @doc "Étiquette une issue (best-effort côté Delegation : résultat ignoré)."
  @callback add_label(
              repo :: String.t(),
              issue_number :: integer(),
              label :: String.t(),
              opts :: keyword()
            ) :: {:ok, :added | :already_present} | {:error, term()}

  @doc "Lit une issue (map API Gitea brute — Delegation lit `\"state\"`)."
  @callback get_issue(repo :: String.t(), number :: integer(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}

  @doc "PRs OUVERTES du repo (maps API Gitea brutes — Delegation lit `head.ref`/`head.sha`)."
  @callback list_open_pulls(repo :: String.t(), opts :: keyword()) ::
              {:ok, [map()]} | {:error, term()}

  @doc """
  Parse une feature-branch système `lcars/issue-<n>-<role>` → `{:ok, {n, role}}`,
  `:error` si le ref n'est pas une feature-branch fleet. Porté par le seam pour que
  `Delegation` n'appelle jamais `Fleet.Pilot.ForgeProtocol` en direct (dep compile).
  """
  @callback parse_feature_branch(head :: String.t()) ::
              {:ok, {issue_number :: integer(), role :: String.t()}} | :error

  @doc "Verdicts de review de la PR (dernière review par reviewer, scopée `head_sha`)."
  @callback pr_review_verdicts(repo :: String.t(), index :: integer(), opts :: keyword()) ::
              {:ok, %{optional(String.t()) => :approved | :changes_requested}}
              | {:error, term()}

  # Défaut canon : le client forge réel côté fleet_pilot. Atom littéral (pas d'appel
  # remote littéral) → aucune dep compile-time. Posé ICI une seule fois.
  @default_client Fleet.Pilot.ForgeClient

  @doc """
  Client forge résolu : config `:fleet_mcp, :forge_client` sinon le défaut canon
  `Fleet.Pilot.ForgeClient`. SOURCE UNIQUE du défaut (même pattern que
  `Fleet.Spawner.LaunchBackend.resolved/0`).
  """
  @spec resolved() :: module()
  def resolved, do: Application.get_env(:fleet_mcp, :forge_client, @default_client)
end
