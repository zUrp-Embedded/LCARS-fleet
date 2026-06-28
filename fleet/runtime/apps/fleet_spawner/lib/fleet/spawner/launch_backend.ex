defmodule Fleet.Spawner.LaunchBackend do
  @moduledoc """
  Behaviour pour exécuter `bin/bwrap_launch.sh` (chantier 4) → `bin/claude_launch.sh`
  (chantier 5) avec ENV vars OAuth résolues.

  Le default `Fleet.Spawner.LaunchBackend.LauncherPortBackend` utilise
  `Port.open/2` (`:spawn_executable`) et retourne immédiatement (modèle
  interactif, pas de flux NDJSON à lire). Tests swappent via
  `Fleet.Spawner.LaunchBackend.StubBackend` pour retourner un Port canned.

  Configurable via :

      config :fleet_spawner, :launch_backend,
        Fleet.Spawner.LaunchBackend.LauncherPortBackend

  ## Contrat N1 — `.claude.json`

  La projection N0 (`Fleet.Spawner.Pod`) n'écrit PLUS `<pod_dir>/.claude.json` : c'est de la
  connaissance schéma-vendor. **Tout vendor launcher** (`claude_launch.sh` et tout futur
  `<vendor>_launch.sh`) DOIT écrire `<pod_dir>/.claude.json` AVANT l'exec, avec au minimum
  `hasCompletedOnboarding: true` + les 3 clés remote-control
  (`remoteControlAtStartup`/`hasUsedRemoteControl`/`remoteDialogSeen`) — sinon le dialog RC bloque
  le pod au boot. La clé `projects` doit être le CWD réel de l'agent (`LCARS_POD_CWD`).
  """

  @doc """
  Lance un pod via la chaîne bwrap_launch → claude_launch.

  ## Inputs

    * `args` — map avec :
      * `:role` — string
      * `:pod_id` — string
      * `:pod_dir` — path absolu pod
      * `:launcher_path` — path absolu du launcher N0 choisi par containment
        (`bwrap_launch.sh` défaut | `host_launch.sh` si containment: none)
      * `:claude_launch_path` — path absolu `claude_launch.sh`
    * `env` — map ENV vars à injecter (OAuth + custom)

  Pas de `:budget_sec`/`:budget_usd`. Le timeout de réponse
  est géré côté Pod GenServer (Process.send_after :result_deadline,
  default par lifetime_scope) ; pas d'API = pas de budget USD.

  ## Returns

    * `{:ok, %{port: port, tmux_session: String.t() | nil}}`
      — pod lancé (Port ouvert immédiatement, modèle interactif sous PTY)
    * `{:error, reason}` — échec
  """
  @callback launch(args :: map(), env :: %{String.t() => String.t()}) ::
              {:ok, %{required(atom()) => any()}} | {:error, term()}

  # Défaut canon : le vrai backend de spawn (Port → bwrap_launch → claude_launch).
  # Posé ICI une seule fois ; les tests le swappent via config `:launch_backend` (StubBackend).
  @default_backend Fleet.Spawner.LaunchBackend.LauncherPortBackend

  @doc """
  Backend de lancement résolu : config `:fleet_spawner, :launch_backend` sinon le défaut
  canon `LauncherPortBackend`. SOURCE UNIQUE du défaut — le spawner (au moment du spawn)
  et la readiness (sonde anti-vert-creux) lisent ici ; aucun des deux ne re-déclare le défaut,
  donc aucun drift possible entre « ce qui lance » et « ce que la readiness croit lancé ».
  """
  @spec resolved() :: module()
  def resolved do
    Application.get_env(:fleet_spawner, :launch_backend, @default_backend)
  end
end
