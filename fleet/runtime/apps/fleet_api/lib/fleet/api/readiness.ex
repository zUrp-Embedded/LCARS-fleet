defmodule Fleet.API.Readiness do
  @moduledoc """
  Read-model P05 — état opérationnel **LIVE** du daemon (anti-vert-creux).

  « Release démarrée ≠ système opérationnel. » `/api/health` répond 200 dès
  que Cowboy a bind `:8080` ; ça ne dit RIEN de l'état de câblage réel
  (registry events chargé, Pilot actif, backends wirés vs placeholders).
  `deep/0` introspecte le système **vivant** (config chargée, registre de
  process, `:persistent_term`) et rend chaque sous-système en clair.

  ## Plan distinct de `mix lcars.contracts.check` (P01)

  `contracts.check` est un gate **source-conformance** (grep statique des
  sources + exit≠0, plan build/CI — R7). Il n'est PAS rejouable depuis une
  release (ni sources ni Mix au runtime). `deep/0` est son **jumeau runtime**
  sur l'autre plan : l'**état opérationnel live**. Les deux sont
  complémentaires — l'un verrouille la conformité du code, l'autre expose ce
  qui est effectivement câblé dans le daemon qui tourne.

  ## Vocabulaire d'état (par sous-système)

    * `:operational` — wiré et fonctionnel comme attendu
    * `:inactive` — **volontairement** off (gate config/env), attendu, PAS une
      faute (ex. Pilot off-par-défaut, rollout progressif) — visible mais ne
      dégrade pas le verdict global (R21)
    * `:degraded` — DEVRAIT être opérationnel mais ne l'est pas → le signal
      anti-vert-creux (ex. registry vide en prod, drain NoOp, launch Stub).
      Bascule le verdict global en `degraded` (R22)

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
      {"pilot.dispatcher", &pilot_dispatcher/0},
      {"coord.backend", &coord_backend/0},
      {"shutdown.dispatcher", &shutdown_dispatcher/0},
      {"launch.backend", &launch_backend/0},
      {"mcp.pod_facing", &mcp_pod_facing/0}
    ]
  end

  # ── Probes (chacune : %{id, state, detail}) ──────────────────────────

  # Registry events chargé ⇒ `Bus.broadcast/2` fail-loud actif. Vide ⇒
  # escape-hatch boot (validation OFF) — le bug registry-vide-prod que B2 a
  # corrigé ; si on le revoit live, c'est dégradé, pas vert-creux.
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

  # Pilot auto-dispatch : OFF-par-défaut (env `LCARS_PILOT_DISPATCHER`) =
  # `:inactive` explicite (R21, attendu, rollout progressif), PAS une faute.
  # ON sans process vivant, ou ON avec 0 route chargée = `:degraded`.
  defp pilot_dispatcher do
    on? = Application.get_env(:fleet_pilot, :start_dispatcher, false)
    pid = Process.whereis(Fleet.Pilot.AutoDispatcher)

    cond do
      not on? ->
        probe("pilot.dispatcher", :inactive, %{
          start_dispatcher: false,
          note: "auto-dispatch OFF (LCARS_PILOT_DISPATCHER) — rollout progressif"
        })

      is_pid(pid) ->
        # Compte de routes lu sur l'état EN MÉMOIRE du dispatcher vivant (pas
        # le YAML disque, qui peut diverger de ce que le process a chargé au
        # boot). 0 route = dispatcher ON mais inopérant → dégradé.
        case live_routes_count(pid) do
          n when is_integer(n) and n > 0 ->
            probe("pilot.dispatcher", :operational, %{routes_loaded: n})

          n when is_integer(n) ->
            probe("pilot.dispatcher", :degraded, %{
              routes_loaded: n,
              note: "dispatcher ON mais 0 route chargée (catalogue forge-routing vide/absent)"
            })

          :error ->
            probe("pilot.dispatcher", :degraded, %{
              note: "AutoDispatcher vivant mais stats injoignable"
            })
        end

      true ->
        probe("pilot.dispatcher", :degraded, %{
          start_dispatcher: true,
          alive: false,
          note: "start_dispatcher=true mais AutoDispatcher absent du registre"
        })
    end
  end

  # Backend d'escalade Cat 5 coord : `NotWiredYet` (ou absent) ⇒ escalades
  # audit-only silencieuses ⇒ `:degraded` (R22). Vrai backend ⇒ operational.
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
    backend =
      Application.get_env(
        :fleet_starfleet,
        :shutdown_dispatcher,
        Fleet.Starfleet.Shutdown.NoOpDispatcher
      )

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
    backend = Application.get_env(:fleet_spawner, :launch_backend)

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

  # MCP pod-facing : transport pull/push des pods. `pod_facing_port` +
  # `mcp_server_spec` tous deux présents ⇒ operational ; tous deux absents ⇒
  # `:inactive` (non configuré, attendu hors-MCP) ; un seul ⇒ `:degraded`.
  defp mcp_pod_facing do
    port = Application.get_env(:fleet_mcp, :pod_facing_port)
    spec = Application.get_env(:fleet_spawner, :mcp_server_spec)

    cond do
      is_nil(port) and is_nil(spec) ->
        probe("mcp.pod_facing", :inactive, %{note: "MCP pod-facing non configuré"})

      not is_nil(port) and not is_nil(spec) ->
        probe("mcp.pod_facing", :operational, %{pod_facing_port: port, mcp_server_spec: true})

      true ->
        probe("mcp.pod_facing", :degraded, %{
          pod_facing_port: port,
          mcp_server_spec: not is_nil(spec),
          note: "MCP partiellement configuré (port ou spec manquant)"
        })
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp probe(id, state, detail), do: %{id: id, state: state, detail: detail}

  # `fleet_pilot` est Ring 2 ; `fleet_api` Ring 4 ne le prend PAS en dépendance
  # compile-time (pas d'inversion de layering). Le read-model interroge donc
  # l'état EN MÉMOIRE du dispatcher vivant via dispatch dynamique guardé :
  # `AutoDispatcher.stats/1` (GenServer.call → `%{routes_count}`). Dep-free,
  # résilient (module absent / process mort / call exit → `:error`).
  defp live_routes_count(pid) do
    mod = Fleet.Pilot.AutoDispatcher

    if Code.ensure_loaded?(mod) and function_exported?(mod, :stats, 1) do
      %{routes_count: n} = apply(mod, :stats, [pid])
      n
    else
      :error
    end
  rescue
    _ -> :error
  catch
    :exit, _ -> :error
  end

  # Un probe qui crash ne fait pas tomber l'endpoint : rabattu en :degraded,
  # en conservant l'id du sous-système (attribution correcte du dégradé).
  defp safe_probe(id, fun) do
    fun.()
  rescue
    e -> %{id: id, state: :degraded, detail: %{error: Exception.message(e)}}
  end
end
