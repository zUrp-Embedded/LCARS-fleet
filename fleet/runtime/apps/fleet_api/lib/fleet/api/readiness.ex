defmodule Fleet.API.Readiness do
  @moduledoc """
  Read-model — état opérationnel **LIVE** du daemon (anti-vert-creux).

  « Release démarrée ≠ système opérationnel. » `/api/health` répond 200 dès
  que Cowboy a bind `:8080` ; ça ne dit RIEN de l'état de câblage réel
  (registry events chargé, Pilot actif, backends wirés vs placeholders).
  `deep/0` introspecte le système **vivant** (config chargée, registre de
  process, `:persistent_term`) et rend chaque sous-système en clair.

  ## Plan distinct de `mix lcars.contracts.check`

  `contracts.check` est un gate **source-conformance** (grep statique des
  sources + exit≠0, joué au build/CI). Il n'est PAS rejouable depuis une
  release (ni sources ni Mix au runtime). `deep/0` est son **jumeau runtime**
  sur l'autre plan : l'**état opérationnel live**. Les deux sont
  complémentaires — l'un verrouille la conformité du code, l'autre expose ce
  qui est effectivement câblé dans le daemon qui tourne.

  ## Vocabulaire d'état (par sous-système)

    * `:operational` — wiré et fonctionnel comme attendu
    * `:inactive` — **volontairement** off (gate config/env), attendu, PAS une
      faute (ex. Pilot off-par-défaut, rollout progressif) — visible mais ne
      dégrade PAS le verdict global
    * `:degraded` — DEVRAIT être opérationnel mais ne l'est pas → le signal
      anti-vert-creux (ex. registry vide en prod, drain NoOp, launch Stub).
      Bascule le verdict global en `degraded`

  Chaque probe est défensif : une exception est rabattue en `:degraded`
  plutôt que de faire planter l'endpoint (read-model résilient).
  """

  @doc """
  État opérationnel deep. Verdict global `operational | degraded` +
  liste des sous-systèmes dégradés + détail par sous-système.
  """
  @spec deep() :: map()
  def deep, do: deep(default_probes())

  @doc """
  Variante injectable : agrège une liste de probes `{id, fun}`. `fun/0` rend
  `%{id, state, detail}`. Le défaut `default_probes/0` sonde le système réel ;
  les tests injectent des probes contrôlées pour exercer l'agrégation seule.
  """
  @spec deep([{String.t(), (-> map())}]) :: map()
  def deep(probes) when is_list(probes) do
    subsystems = Enum.map(probes, fn {id, fun} -> safe_probe(id, fun) end)

    degraded =
      subsystems
      |> Enum.filter(&(&1.state == :degraded))
      |> Enum.map(& &1.id)

    %{
      status: if(degraded == [], do: "operational", else: "degraded"),
      degraded: degraded,
      subsystems: subsystems,
      ts: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp default_probes do
    [
      {"event.registry", &event_registry/0},
      {"coord.backend", &coord_backend/0},
      {"shutdown.dispatcher", &shutdown_dispatcher/0},
      {"launch.backend", &launch_backend/0},
      {"mcp.pod_facing", &mcp_pod_facing/0},
      {"pilot.step", &pilot_step/0}
    ]
  end

  # ── Probes (chacune : %{id, state, detail}) ──────────────────────────

  # Registry events chargé ⇒ `Bus.broadcast/2` fail-loud actif. Vide ⇒
  # escape-hatch boot (validation OFF) = registry-vide-en-prod, un bug réel
  # (broadcasts non validés) ; le sonder ici l'expose comme dégradé, pas vert-creux.
  defp event_registry do
    size = MapSet.size(Fleet.EventRouter.Bus.authorized_event_types())

    if size > 0 do
      probe("event.registry", :operational, %{
        authorized_types: size,
        note: "validation broadcast fail-loud active"
      })
    else
      probe("event.registry", :degraded, %{
        authorized_types: 0,
        note: "registry vide — validation broadcast OFF (escape-hatch boot)"
      })
    end
  end

  # Le rail forge-state-machine (Poller step + StepRunConsumer) est sondé — sa mort
  # runtime (singleton tombé) bascule en `:degraded` au lieu d'un vert-creux. Délégué à fleet_pilot,
  # qui possède la topologie du rail (`Fleet.Pilot.Application.step_status/0`) — pas de fuite des
  # noms de process Ring 2 dans Ring 4. `:inactive` si step off (n'altère pas le verdict global).
  # (Le rail forge-state-machine est l'UNIQUE rail de dispatch : pas de sonde dispatcher RAM legacy.)
  defp pilot_step do
    {state, detail} = Fleet.Pilot.Application.step_status()
    probe("pilot.step", state, detail)
  end

  # Backend d'escalade Cat 5 coord : `NotWiredYet` (ou absent) ⇒ escalades
  # audit-only silencieuses ⇒ `:degraded`. Vrai backend ⇒ operational.
  # NB : `Fleet.Coord` est un module PUR (Policies = fonctions pures, aucun
  # GenServer — cf. fleet_coord/application.ex) ; il n'y a pas de process à
  # sonder pour la liveness. La présence du backend en config = operational
  # est donc correct (pas de cas « wiré mais process mort »).
  defp coord_backend do
    backend = Application.get_env(:fleet_starfleet, :coord_backend)

    if backend in [nil, Fleet.Starfleet.CoordBackend.NotWiredYet] do
      probe("coord.backend", :degraded, %{
        backend: inspect(backend),
        note: "NotWiredYet/absent — escalades Cat 5 audit-only silencieuses"
      })
    else
      probe("coord.backend", :operational, %{backend: inspect(backend)})
    end
  end

  # Drain de shutdown : `NoOpDispatcher` (défaut test/fallback) ⇒ drain immédiat
  # 0 in-flight = honnête-dégradé (le drain ne draine pas). Operational quand le
  # backend prod `AggregateDispatcher` est câblé (seam `:shutdown_dispatcher`).
  defp shutdown_dispatcher do
    # Lit le backend via la SOURCE UNIQUE du propriétaire (`Fleet.Starfleet.Shutdown`, qui
    # l'utilise aussi à son init) au lieu de re-déclarer le défaut `NoOpDispatcher` ici — pas
    # de second défaut à garder aligné.
    backend = Fleet.Starfleet.Shutdown.configured_dispatcher()

    if backend == Fleet.Starfleet.Shutdown.NoOpDispatcher do
      probe("shutdown.dispatcher", :degraded, %{
        backend: "NoOpDispatcher",
        note: "drain NoOp (AggregateDispatcher non câblé) — 0 in-flight, drain immédiat"
      })
    else
      probe("shutdown.dispatcher", :operational, %{backend: inspect(backend)})
    end
  end

  # Backend de lancement de pod : `StubBackend` = inerte (test/non-prod),
  # aucun spawn réel ⇒ `:degraded` ; backend réel (LauncherPort/Tmux) ⇒
  # operational ; absent ⇒ degraded.
  defp launch_backend do
    # Lit le backend via la SOURCE UNIQUE du propriétaire (`Fleet.Spawner.LaunchBackend.resolved/0`,
    # que le spawner appelle aussi au spawn) au lieu de re-copier le défaut `LauncherPortBackend` ici.
    # Conséquence : sur une fleet saine où la clé n'est pas posée, readiness lit le MÊME défaut que
    # ce qui lance réellement les pods → pas de `:degraded` permanent fantôme, pas de défaut à aligner.
    backend = Fleet.Spawner.LaunchBackend.resolved()

    cond do
      is_nil(backend) ->
        probe("launch.backend", :degraded, %{backend: "nil", note: "non configuré"})

      backend == Fleet.Spawner.LaunchBackend.StubBackend ->
        probe("launch.backend", :degraded, %{
          backend: "StubBackend",
          note: "backend inerte (test/non-prod) — aucun spawn réel"
        })

      true ->
        probe("launch.backend", :operational, %{backend: inspect(backend)})
    end
  end

  # MCP pod-facing : transport pull des pods. Sonde le PROCESS RÉEL (le
  # DynamicSupervisor d'accepteurs de socket per-pod tourne-t-il ?) délégué au
  # propriétaire de la topologie `Fleet.MCP.Supervisor.pod_facing_status/0` — pas
  # un knob de config. Délégation = pas de fuite des noms de process Ring 3 dans
  # Ring 4 (même pattern que `pilot.step`). Le `mcp_server_spec` (côté spawner)
  # reste sondé en config : c'est le spec injecté AUX pods, pas un process — sa
  # présence/absence est l'état réel à ce niveau. Substrat vivant + spec présent →
  # `:operational` ; substrat mort, OU vivant mais spec absent (pods non câblés) →
  # `:degraded`.
  defp mcp_pod_facing do
    {sub_state, sub_detail} = Fleet.MCP.Supervisor.pod_facing_status()
    spec_present? = not is_nil(Application.get_env(:fleet_spawner, :mcp_server_spec))
    detail = Map.put(sub_detail, :mcp_server_spec, spec_present?)

    case sub_state do
      :operational when spec_present? ->
        probe("mcp.pod_facing", :operational, detail)

      :operational ->
        probe(
          "mcp.pod_facing",
          :degraded,
          Map.put(
            detail,
            :note,
            "substrat socket vivant mais mcp_server_spec absent (pods non câblés)"
          )
        )

      :degraded ->
        probe("mcp.pod_facing", :degraded, detail)
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp probe(id, state, detail), do: %{id: id, state: state, detail: detail}

  # Un probe qui crash ne fait pas tomber l'endpoint : rabattu en :degraded,
  # en conservant l'id du sous-système (attribution correcte du dégradé).
  defp safe_probe(id, fun) do
    fun.()
  rescue
    e -> %{id: id, state: :degraded, detail: %{error: Exception.message(e)}}
  end
end
