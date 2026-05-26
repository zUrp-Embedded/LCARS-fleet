defmodule Fleet.Spawner.LaunchBackend do
  @moduledoc """
  Behaviour pour exécuter `bin/bwrap_launch.sh` (chantier 4) → `bin/claude_launch.sh`
  (chantier 5) avec ENV vars OAuth résolues.

  Le default `Fleet.Spawner.LaunchBackend.PortBackend` utilise
  `Port.open/2` (`:spawn_executable`) et lit la sortie. Tests
  swappent via `Fleet.Spawner.LaunchBackend.StubBackend` pour
  retourner des données canned (init message NDJSON, exit code).

  Configurable via :

      config :fleet_spawner, :launch_backend,
        Fleet.Spawner.LaunchBackend.PortBackend
  """

  @doc """
  Lance un pod via la chaîne bwrap_launch → claude_launch.

  ## Inputs

    * `args` — map avec :
      * `:role` — string
      * `:pod_id` — string
      * `:pod_dir` — path absolu pod
      * `:bwrap_launch_path` — path absolu `bwrap_launch.sh`
      * `:claude_launch_path` — path absolu `claude_launch.sh`
    * `env` — map ENV vars à injecter (OAuth + custom)

  R0.8-brick4 : `:budget_sec`/`:budget_usd` retirés. Le timeout de réponse
  est géré côté Pod GenServer (Process.send_after :result_deadline,
  default par lifetime_scope) ; pas d'API = pas de budget USD.

  ## Returns

    * `{:ok, %{port: port, init_message: map() | nil, ndjson_log: path}}`
      — pod lancé, init message capturé (ou nil si pas encore reçu)
    * `{:error, reason}` — échec

  Les implémentations sont libres de bloquer pour récupérer le
  premier `init` message (boot validation) avant de retourner.
  """
  @callback launch(args :: map(), env :: %{String.t() => String.t()}) ::
              {:ok, %{required(atom()) => any()}} | {:error, term()}
end
