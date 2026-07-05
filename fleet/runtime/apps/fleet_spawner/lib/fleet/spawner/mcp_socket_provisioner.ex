defmodule Fleet.Spawner.McpSocketProvisioner do
  @moduledoc """
  Behaviour du provisionneur de socket MCP per-pod — le CONTRAT du seam runtime
  `:mcp_socket_provisioner`, consommé par `Fleet.Spawner.Pod.McpProvision`
  (états `:projecting` / filet `terminate/3` du Pod).

  ## Pourquoi un seam RUNTIME (et pas une dep compile)

  `fleet_spawner` est Ring 1, `fleet_mcp` est Ring 2 (au-dessus) : une dep mix.exs
  `fleet_spawner → fleet_mcp` serait une dep MONTANTE (ring bas → ring haut),
  INTERDITE par le layering. Le module est donc résolu au RUNTIME (`resolved/0` :
  app-env + défaut en atom littéral → AUCUNE dep compile-time, donc aucun cycle).
  L'umbrella démarre toutes les apps → l'impl réelle est vivante quand un pod
  tourne. Seam déclaré dans `fleet_event_router/priv/allowed_graph.yaml`
  (section `seams`, direction `up`) — le contrat vit ICI, chez le CONSOMMATEUR.

  ## Implémentations

    * `Fleet.MCP.PodSocketSupervisor` — impl RÉELLE (défaut canon). Elle vit dans
      `fleet_mcp`, qui ne dépend PAS de `fleet_spawner` : elle ne PEUT PAS adopter
      ce behaviour (`@behaviour` = référence compile, créerait l'arête interdite)
      et reste DUCK-TYPÉE, avec un commentaire croisé dans son moduledoc. Ce
      module-ci est la SOURCE DE VÉRITÉ du contrat — toute évolution se répercute
      des deux côtés à la main.
    * `Fleet.Spawner.MCPSocketStub` — stub test (même app → adopte le behaviour,
      le compilateur vérifie la conformité). Rend un chemin sous tmp SANS créer
      de socket ; posé par `config/test.exs` (mirror de `launch_backend: StubBackend`).
  """

  @doc """
  ENSURE (avant le launch) : crée le listener + le fichier socket de ce pod et
  rend le CHEMIN HOST du fichier socket. Idempotent (re-appel → même chemin,
  pas de doublon). Le fichier DOIT exister au retour : le bind bwrap échouerait
  sinon (le launcher monte la socket dans le sandbox du pod).
  """
  @callback ensure_pod_socket(pod_id :: String.t()) :: {:ok, Path.t()} | {:error, term()}

  @doc """
  RELEASE (teardown) : arrête le listener ET retire le fichier socket (fermer le
  socket libère le FD, PAS le fichier). Idempotent — un release d'un pod déjà
  libéré rend `:ok`.
  """
  @callback release_pod_socket(pod_id :: String.t()) :: :ok

  # Défaut canon : l'impl réelle côté fleet_mcp. Atom littéral (pas d'appel remote
  # littéral) → aucune dep compile-time. Posé ICI une seule fois.
  @default_provisioner Fleet.MCP.PodSocketSupervisor

  @doc """
  Provisionneur résolu : config `:fleet_spawner, :mcp_socket_provisioner` sinon le
  défaut canon `Fleet.MCP.PodSocketSupervisor`. SOURCE UNIQUE du défaut (même
  pattern que `Fleet.Spawner.LaunchBackend.resolved/0`) — le seul lecteur runtime
  est `Pod.McpProvision`, tout futur lecteur passe ici au lieu de re-déclarer.
  """
  @spec resolved() :: module()
  def resolved do
    Application.get_env(:fleet_spawner, :mcp_socket_provisioner, @default_provisioner)
  end
end
