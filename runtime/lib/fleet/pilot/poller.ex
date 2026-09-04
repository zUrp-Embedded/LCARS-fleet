defmodule Fleet.Pilot.Poller do
  @moduledoc """
  Reactor of the forge-state-machine rail (**STEP mode only**), **multi-project**: at each
  tick it DISCOVERS the repos of every catalogue org via `list_org_repos` (one org per installed
  catalogue; every repo of such an org IS a fleet project), then delegates the open issues + PRs
  to role spawning via `StepDispatcher`.

  ## Role

  The forge IS the state machine; this poller is its reactor. At each tick, for EVERY repo
  of the catalogue orgs, it lists the open **issues** + **PRs** and delegates:

    * **assigned issue** (assignee=human owner), unlocked, without an open PR → spawn the role
      the engraved route names (`StepDispatcher.dispatch_issue`; the workflow_map step decides,
      never a default producer).
    * **PR** with a requested reviewer → spawn the **judge**; PR `REQUEST_CHANGES` without a reviewer → re-spawn
      the **producer** for the rework (`StepDispatcher.dispatch_review`).
    * `lcars-in-flight` lock → skip (a pod is already working the brick). **Per-repo ceiling**
      (`Lease` + `Admission.max_fan/2`): at most `max_fan` active workflow_runs per repo — the
      project's declaration, else the fleet default (5); a declaration of 1 is the serial project.

  ## Robustness

    * **Jitter ±10%** on the interval — anti thundering-herd (N daemons that restart together).
    * **Exponential backoff** on API errors (capped at 5 min) — a forge that is down does not flood the logs.
    * **`try/rescue` safety-net** on `do_poll/1` — a bug in the dispatch path does not crash the poller.
    * **Telemetry** `[:lcars_fleet, :pilot_poller, :poll]` (duration_ms, dispatched, skipped, errors).

  ## Sub-modules

    * `Backoff` — PURE computation of the delay (jitter + exponential backoff); the GenServer keeps
      the effect (`schedule/1`) and the rescue (`safe_poll`).
    * `Lease` — per-repo admission ceiling (ENGAGED/QUEUED classification + dispatch under
      `max_fan`, issues path); hardened boundary `Lease.Seams`, tally vocabulary.
    * `Reconciliation` — reclaiming of orphaned `lcars-in-flight` locks (the 2-tick
      grace — cross-tick state — stays HERE, `orphan_lock_suspects`).

  Stay HERE: the loop (org-repo discovery + admission + tally orchestration + state
  backoff), the pulls path (`step_process_pulls`, not guarded by the lease) and the throttled
  awaits-arch re-kick (coupled to `poll_count`; fired ONCE per tick by `do_poll` on the
  cross-repo union — `ArchWake` groups the awaits BY REPO and wakes each project's architect
  independently, so a single call here fans out to all of them).

  ## Init configuration

    * (No `:repo` opt at init: the struct field `repo` remains as the iteration carrier —
      set by `do_poll` for each discovered repo — but is not an entry seam. Org-membership
      discovery is the only source of repos.)
    * `:human` — test seam; default `Fleet.Credentials.Human.current!()` (fail-loud), the
      REAL required source of multi-user scoping.
    * `:interval_ms` — default `30_000` (30s).
    * `:forge_opts` — ForgeClient keyword (base_url, token, req_options).
    * test seams: `:forge_client`, `:loader`, `:workflow_map_loader`, `:spawner` (injected if non-nil).
    * `:start_tick?` — default `true`; `false` = no auto first tick (tests drive via `force_poll/1`).
  """

  use GenServer
  require Logger

  alias Fleet.Forge.Payload
  alias Fleet.Opts
  alias Fleet.Pilot.Poller.Reconciliation
  alias Fleet.Pilot.StepDispatcher

  # PURE tick timing (anti-herd jitter + capped exponential backoff) — the GenServer keeps
  # the EFFECT (`schedule/1` = Process.send_after) and the rescue (`safe_poll`), Backoff yields the delay.
  alias Fleet.Pilot.Poller.Backoff

  # Per-repo admission ceiling (ENGAGED/QUEUED classification + dispatch under `max_fan`) — the
  # business CORE of the issues path. Hardened boundary: reads a narrow `Lease.Seams`
  # (`lease_seams/1`), prod defaults resolved HERE. Also owns the tally vocabulary
  # (`zero_tally/merge_tally`).
  alias Fleet.Pilot.Poller.Lease

  # THE passage point of the two dispatch rails. Every TRANSVERSE rule (accounting, wait
  # vocabulary) lives there and both rails traverse it — because each of the two had already
  # forgotten a different one of those rules, and nothing said so.
  alias Fleet.Pilot.Poller.Admission

  # HUMAN lock placed on the ISSUE at escalation (gatekeeper verdict escalate/halt/redirect, or unresolved
  # conflict). The poller computes the SET of issues carrying it (already listed at the tick → zero I/O) and threads
  # it to the pulls → `dispatch_review` skips the judge of a PR whose parent issue awaits the arch.
  @awaits_arch Fleet.Labels.awaits_arch()

  @default_interval_ms 30_000

  # « Premier reveil immediat, protection DERRIERE lui » : le plafond protege APRES le premier
  # reveil, il ne le retarde pas.
  #
  # ⚠ JAMAIS UNE GRILLE D'ECHANTILLONNAGE (`rem(poll_count, N)`) : une grille ferait tirer a une
  # escalade FRAICHE une loterie de latence de 0 a 5 minutes. Le plafond existe parce qu'un reveil
  # peut couter un TOUR de claude — sans lui, un label qui traine en declenche un toutes les 30 s.
  @awaits_rekick_cooldown_ms 300_000

  # Coalescence window of the webhook kick: a burst of events within the window = ONE poll.
  @gitea_kick_debounce_ms 1_000

  # Cadence of the per-repo main-protection desired-state pass (1 GET per repo per period;
  # first tick after boot rechecks everything — boot-time reconciliation is the feature,
  # not a burst to shave). Regular ticks only, same rationale as the arch net.
  @protection_recheck_ms 3_600_000

  defstruct [
    :repo,
    :interval_ms,
    # The human of THIS fleet (OS user, `Human.current!()`). Multi-user scoping: we dispatch
    # ONLY its issues (otherwise Alice's poller spawns for Bob). Test seam: opt `:human`.
    :my_human,
    # Les orgs de la frontiere d'admission — UNE PAR CATALOGUE INSTALLE, l'org portant le nom du
    # catalogue. Tout depot d'une de ces orgs EST un projet de la fleet. Seam de test : `:orgs`, ou
    # `:org` en singleton pour les appelants qui en nommaient une.
    :orgs,
    :forge_client_override,
    forge_opts: [],
    loader: nil,
    workflow_map_loader: nil,
    spawner: nil,
    task_queue: nil,
    # Wake recovery seam threaded down to `StepDispatcher.dispatch_issue` (default nil → the real
    # `WakeRecovery.wake/3`). Makes the contract "missed wake ⇒ workflow_run started, lease TAKEN" testable without hitting
    # the real IncidentRegistry/tmux.
    wake_recovery: nil,
    # G6 seam: escalation of an unreadable workflow_map (default nil → `IncidentRegistry.record_or_escalate/4`).
    # Makes "durably missing map ⇒ sysadmin escalation" testable without hitting the real registry/forge.
    incident_fun: nil,
    # Escalade du SUBSTRAT (JG-059) — la racine des faces absente n'est pas une propriete d'un depot
    # mais une panne de la boite. Meme forme de seam que `incident_fun` : nil → `escalate_gated/5`.
    escalate_fun: nil,
    # Presence du SUBSTRAT (JG-059). `Fleet.Layout.ops_root/0` est un litteral — c'est voulu, un
    # fait une source — donc un test ne peut pas le deplacer, et il ne doit pas ecrire dans `/home`.
    # Ce seam est la seule facon d'exercer le GARDE PAR DEPOT sur une machine qui n'a pas la racine :
    # sans lui, les cas « ce depot n'est pas onboarde » et « le sol a disparu » ne sont pas
    # separables en test. Defaut nil → `File.dir?/1` sur la vraie racine.
    substrate_present_fun: nil,
    # Pod enumeration healthy? Carried to speak at the TRANSITION only (BL-6-47.3): a failed
    # enumeration is a correct fail-safe AND a potentially durable outage, and saying it every tick
    # would drown the trace it exists to raise. Starts `true` — the first failure IS a transition.
    pods_snapshot_ok?: true,
    # Desired-state pass of the main branch-protection (default nil →
    # `Fleet.Project.Onboard.reconcile_main_protection/2`) — seam for tests (zero forge).
    protection_reconciler: nil,
    # Keeper of the per-project architect (default nil → `Project.Architect.ensure_alive/2`) —
    # seam for tests (zero forge, zero tmux).
    architect_keeper: nil,
    # repo → monotonic ms of its last protection recheck (throttle; RAM loss on restart =
    # recheck at next boot, convergent by construction).
    protection_rechecked: %{},
    # Webhook-kick coalescence: true = an accelerated poll is already scheduled, the
    # following gitea.* events of the burst schedule NOTHING.
    gitea_kick_pending?: false,
    poll_count: 0,
    # Kick-polls (webhook hint, :kick mode) counted APART: poll_count is the unit of the
    # tick-cadenced invariants (arch re-kick throttle, 2-tick grace) — a kick must not consume them.
    kick_count: 0,
    error_count: 0,
    err_streak: 0,
    last_error: nil,
    # Number of DISPATCH errors (per item) on the last tick. The forge list
    # (`list_open_*`) can succeed while some `dispatch_*` fail — these errors are surfaced
    # here for observability (`stats/1`) + telemetry; they do NOT feed `err_streak` (the
    # multi-project `do_poll` resets the streak to 0 each successful tick, keeping only
    # `orphan_lock_suspects`) → they do not trigger backoff.
    last_tally_errors: 0,
    # Monotonic ms of the last awaits-arch net kick that actually SENT a signal (:offered /
    # :woken_pending). nil = never → the net fires on the FIRST eligible tick (≤1 tick of
    # latency when the immediate kick was lost). :busy sends nothing → NOT stamped (once the
    # arch frees with the label still present, the net fires without waiting a full cooldown).
    last_arch_rekick_at: nil,
    # Lock reconciliation: refs `{repo, :issue|:pr, n}` seen ORPHANED (`lcars-in-flight` lock
    # without a live pod) at the previous tick. 2-REGULAR-tick grace (same grace as the PodWarden):
    # we only reclaim on the 2nd consecutive REGULAR tick (avoids unlocking a freshly dispatched pod
    # or one in the process of dying). Webhook kick-polls (:kick) pass this set through UNCHANGED —
    # counting kicks as ticks would compress the ~60s grace to ~2s under the forge traffic generated
    # by the completion sequence itself (reclaim mid-publication → double dispatch).
    orphan_lock_suspects: MapSet.new(),
    # Orgs PROVEN absent from the forge (404) at the last discovery, so the drop is announced ONCE
    # per transition instead of every tick. An operator who enabled a catalogue nobody enrolled must
    # read the sentence; the same sentence repeated every 30s is one they learn to scroll past.
    absent_orgs: MapSet.new()
  ]

  # No `@type t` on purpose: the commented defstruct above IS the state contract — a type list
  # that must be manually mirrored rusts silently (same reason comment-counters are banned).

  # ============================================================
  # Public API
  # ============================================================

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {gs_opts, init_opts} = Keyword.split(opts, [:name])
    name = Keyword.get(gs_opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, init_opts, name: name)
  end

  @doc "Force an immediate (synchronous) poll. Used by tests + ops."
  @spec force_poll(GenServer.server()) :: %{
          dispatched: non_neg_integer(),
          skipped: non_neg_integer(),
          errors: non_neg_integer()
        }
  def force_poll(server \\ __MODULE__), do: GenServer.call(server, :force_poll, 30_000)

  @doc "Runtime stats: poll_count, error_count, err_streak, last_error, last_tally_errors."
  @spec stats(GenServer.server()) :: map()
  def stats(server \\ __MODULE__), do: GenServer.call(server, :stats)

  # ============================================================
  # GenServer callbacks
  # ============================================================

  @impl GenServer
  def init(opts) do
    # Multi-project: no mandatory `:repo` — the poller DISCOVERS its projects by ORG-MEMBERSHIP
    # (`list_org_repos(org)` per catalogue org — every repo of such an org IS a fleet project). `:repo` stays accepted
    # (tests/seam) but is NOT the source (do_poll overwrites it per iteration). `my_human` = the REAL
    # required source of SCOPING (`Human.current!()` fail-loud — a poller that does not know WHO it is cannot
    # scope its issues via `assigned_by`).
    state = %__MODULE__{
      my_human: Keyword.get(opts, :human) || Fleet.Credentials.Human.current!(),
      orgs: resolve_orgs(opts),
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      forge_client_override: Keyword.get(opts, :forge_client),
      forge_opts: Keyword.get(opts, :forge_opts, []),
      loader: Keyword.get(opts, :loader),
      workflow_map_loader: Keyword.get(opts, :workflow_map_loader),
      spawner: Keyword.get(opts, :spawner),
      task_queue: Keyword.get(opts, :task_queue),
      wake_recovery: Keyword.get(opts, :wake_recovery),
      incident_fun: Keyword.get(opts, :incident_fun),
      escalate_fun: Keyword.get(opts, :escalate_fun),
      substrate_present_fun: Keyword.get(opts, :substrate_present_fun),
      protection_reconciler: Keyword.get(opts, :protection_reconciler),
      architect_keeper: Keyword.get(opts, :architect_keeper)
    }

    _ =
      if Keyword.get(opts, :start_tick?, true) do
        schedule(Backoff.jitter(state.interval_ms))
      end

    # Webhook gitea.* subscription — a poll-latency ACCELERATOR only. Doctrine: the poll
    # remains THE truth (forge-state-machine) — the event is a HINT, never data (payload
    # ignored). Opt-in (default false = test hermeticity: no stray Bus subscribe in async);
    # wired true by Application.step_children! (prod).
    _ =
      if Keyword.get(opts, :subscribe_gitea, false) do
        :ok = Fleet.EventRouter.Bus.subscribe()
      end

    Logger.info(
      "Poller: start mode=step MULTI-PROJECT orgs=#{Enum.join(state.orgs, ",")} human=#{state.my_human} " <>
        "interval=#{state.interval_ms}ms jitter=±10%"
    )

    {:ok, state}
  end

  @impl GenServer
  def handle_info(:poll, state) do
    # `Quiesce.busy/1`: the tick's synchronous work (dispatch, review lifecycle, merge)
    # is in-flight the drain must WAIT for — it is neither a broker work-item nor a
    # completion offload, so without this wrap a stop could be accepted mid-merge.
    {_result, new_state} = Fleet.Shutdown.Quiesce.busy(fn -> safe_poll(state) end)
    schedule(Backoff.next_delay(new_state.err_streak, new_state.interval_ms))
    {:noreply, new_state}
  end

  # Z6e — webhook hint: a gitea.* event = "the forge moved" → accelerated poll via a
  # DEDICATED :gitea_kick message (⚠ NOT :poll — its handler re-schedules the next tick:
  # injecting :poll would create a permanent PARALLEL CHAIN; :gitea_kick polls without
  # touching the chain). 1s coalescence: a burst of N webhooks = 1 poll.
  def handle_info(%Fleet.Event{type: type}, %__MODULE__{} = state) do
    if gitea_event?(type) and not state.gitea_kick_pending? do
      _ = Process.send_after(self(), :gitea_kick, @gitea_kick_debounce_ms)
      {:noreply, %{state | gitea_kick_pending?: true}}
    else
      {:noreply, state}
    end
  end

  def handle_info(:gitea_kick, state) do
    # :kick mode = DISPATCH-ONLY (the kick is a HINT, the regular tick is the truth):
    # no reconciliation (2-tick grace calibrated in REGULAR ticks), no arch re-kick
    # (same for the throttle), no poll_count. A kick accelerates dispatch; it consumes
    # no tick-based clock.
    {_result, new_state} =
      Fleet.Shutdown.Quiesce.busy(fn ->
        safe_poll(%{state | gitea_kick_pending?: false}, :kick)
      end)

    {:noreply, new_state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp gitea_event?(type) when is_atom(type),
    do: String.starts_with?(Atom.to_string(type), "gitea.")

  @impl GenServer
  # force_poll = deliberate OPERATOR action → a FULL tick (:tick), reconciliation included:
  # the human asks for a real poll, not a hint. (Tests drive the 2-tick grace via consecutive
  # force_polls — that semantic is a contract.)
  def handle_call(:force_poll, _from, state) do
    {result, new_state} = safe_poll(state, :tick)
    {:reply, result, new_state}
  end

  def handle_call(:stats, _from, state) do
    {:reply,
     %{
       # Ce que ce poller SURVEILLE — une org par catalogue installe. Sans ca, « pourquoi ce projet
       # n'est-il jamais pris » n'a pas de reponse observable : la ligne de demarrage le dit une
       # fois, et un operateur qui arrive apres ne l'a plus.
       orgs: state.orgs,
       poll_count: state.poll_count,
       kick_count: state.kick_count,
       error_count: state.error_count,
       err_streak: state.err_streak,
       last_error: state.last_error,
       last_tally_errors: state.last_tally_errors
     }, state}
  end

  # ============================================================
  # Internals — scheduling / safety
  # ============================================================

  defp schedule(interval_ms) when is_integer(interval_ms) and interval_ms > 0 do
    Process.send_after(self(), :poll, interval_ms)
  end

  # Returns `{result, new_state}` — rescue-wrapped. Shared by the tick (which throws away the
  # result), force_poll (which returns it) AND the webhook kick (`mode: :kick`, dispatch-only)
  # → none of them bypasses the rescue.
  defp safe_poll(state, mode \\ :tick) do
    do_poll(state, mode)
  rescue
    exception -> poll_crash(state, exception, "crash")
  catch
    kind, reason -> poll_crash(state, {kind, reason}, "exit/throw")
  end

  # rescue AND catch :exit/:throw — a `GenServer.call` to a dead dep (enqueue→TaskQueue,
  # spawn→Spawner) raises `:exit`, NOT `{:error}`; without the catch, the loop crashed (≠ the "state preserved"
  # that is announced). We degrade gracefully (err_streak + backoff, state preserved), like
  # `Reconciliation.live_owned_refs` (a `GenServer.call` can always `:exit` if the target dies — never
  # let it bubble up bare).
  defp poll_crash(state, detail, kind_label) do
    Logger.error(
      "Poller: unexpected #{kind_label} in do_poll: #{inspect(detail)} — state preserved"
    )

    {%{Lease.zero_tally() | errors: 1},
     %{
       state
       | error_count: state.error_count + 1,
         err_streak: state.err_streak + 1,
         last_error: inspect(detail)
     }}
  end

  # ============================================================
  # Internals — GenServer poll orchestration
  # ============================================================

  # ⚠ UNE ORG ABSENTE N'EST PAS UNE ORG ILLISIBLE. Le fail-closed vaut parce qu'« une decouverte
  # partielle ne se distingue pas de "pas de travail" » — raison qui ne s'applique PAS a un 404 :
  # une org qui N'EXISTE PAS ne porte aucun depot, donc la retirer ne cache rien par construction.
  # Un 5xx, un timeout ou un 403 laissent au contraire des depots peut-etre non lus, d'ou le `halt`.
  #
  # Les absentes REMONTENT au lieu d'etre logguees ici : seul le site qui tient l'etat sait si
  # l'absence est NOUVELLE, et repeter la phrase a chaque tick la rend invisible comme le silence.
  defp discover(forge, state) do
    Enum.reduce_while(state.orgs, {:ok, [], []}, fn org, {:ok, acc, absent} ->
      case forge.list_org_repos(org, state.forge_opts) do
        {:ok, repos} -> {:cont, {:ok, acc ++ repos, absent}}
        {:error, {:http, 404, _}} -> {:cont, {:ok, acc, [org | absent]}}
        {:error, reason} -> {:halt, {:error, {org, reason}}}
      end
    end)
  end

  # Announce a PROVEN-absent org once per transition, and name the gesture that ends it. The message
  # is the only place the operator learns that a catalogue this box serves is inert: the material is
  # here and the forge never carried its org — half an install, and the half that is missing is the
  # one that mints the accounts every dispatch needs.
  defp note_absent_orgs(state, absent) do
    now = MapSet.new(absent)

    for org <- MapSet.difference(now, state.absent_orgs) do
      Logger.warning(
        "Poller: catalogue #{inspect(org)} has its material on this box but its org does NOT " <>
          "exist on the forge (404) — DROPPED from discovery. Nothing is hidden by the drop: an " <>
          "org that does not exist carries no repository. Replay `lcars catalogue install " <>
          "#{org}` (admin, inside the box) — it is convergent and it lays both halves."
      )
    end

    for org <- MapSet.difference(state.absent_orgs, now) do
      Logger.info("Poller: org #{inspect(org)} now exists on the forge — discovery resumes on it")
    end

    %{state | absent_orgs: now}
  end

  # `:orgs` d'abord (la forme), `:org` ensuite (un singleton — les appelants qui en nommaient une),
  # puis la config, puis les catalogues installes : l'org EST le nom du catalogue, donc la liste se
  # derive au lieu de se tenir.
  defp resolve_orgs(opts) do
    cond do
      is_list(orgs = Keyword.get(opts, :orgs)) and orgs != [] -> orgs
      is_binary(org = Keyword.get(opts, :org)) -> [org]
      is_binary(org = Application.get_env(:lcars_fleet, :pilot_fleet_org)) -> [org]
      true -> Fleet.Catalogue.installed_names()
    end
  end

  defp do_poll(state, mode) do
    # `started` captured BEFORE the forge call: `list_org_repos` is precisely the SLOW call when
    # the forge degrades — capturing after it reported duration_ms≈0 on exactly the failure case
    # an operator watches for (blind metric where it matters most).
    started = System.monotonic_time()
    forge = step_forge_client(state)

    # DECOUVERTE FAIL-CLOSED SUR TOUTES LES ORGS : une org ILLISIBLE fait echouer le tick entier au
    # lieu de rendre une liste partielle. Une decouverte partielle ne se distingue pas de « pas de
    # travail » pour les projets manquants — elle ne casse rien, elle rend muet, ce qui est pire.
    # Une org ABSENTE (404) est l'autre cas, et il sort ici en `absent` sans faire tomber la passe :
    # elle ne porte aucun depot, donc rien n'est rendu muet (cf. `discover/2`).
    case discover(forge, state) do
      {:ok, repos, absent} ->
        state = note_absent_orgs(state, absent)

        # :kick does NOT touch poll_count: it is the UNIT of the tick-cadenced invariants
        # (arch re-kick throttle below, 2-tick grace in step_do_poll) — a webhook burst must not
        # consume those clocks (the kick is a hint, the regular tick is the truth).
        base =
          case mode do
            :tick -> %{state | err_streak: 0, poll_count: state.poll_count + 1, last_error: nil}
            :kick -> %{state | err_streak: 0, kick_count: state.kick_count + 1, last_error: nil}
          end

        # ADMISSION = ORG-MEMBERSHIP : l'org EST la frontiere du groupe de confiance, tenue en amont
        # par l'admin humain — LCARS n'est pas du multi-tenant adversarial. Le scoping par humain
        # reste `assigned_by`, au niveau de l'issue : la fleet ne traite QUE ses issues, meme quand
        # `list_org_repos` lui montre les depots des autres humains du groupe.
        #
        # ⚠ UN SEUL `list_pods` POUR TOUT LE TICK (BL-6-40) : par depot, ce serait R appels au
        # Spawner a 5 s de timeout pour un instantane qui ne change pas utilement d'un depot au
        # suivant. Il
        # voyage en PARAMETRE explicite — dans `%Seams{}` il contredirait le contrat « les seams
        # reconcile LISENT », dans `state` il deviendrait un cache a invalider.
        #
        # `:tick` SEULEMENT : le kick ne reconcilie pas, donc prendre l'instantane pour lui AJOUTERAIT
        # un appel au lieu d'en retirer un.
        pods =
          if mode == :tick,
            do: Reconciliation.snapshot_pods(state.spawner || Fleet.Spawner),
            else: :none

        base = note_pods_snapshot(base, pods)

        # ⚠ LE FILET EST ICI, PAR DEPOT, ET IL NE REMPLACE PAS CELUI DU DESSUS. `safe_poll/2` capture
        # au-dessus du fold, donc une levee y privait de service TOUS les depots suivants — et comme
        # la cause est deterministe, a chaque tick. `safe_poll/2` garde son role pour ce qui est hors
        # du fold.
        #
        # ⚠ L'ACCUMULATEUR N'EST PAS RENDU TEL QUEL sur une levee : laisser `acc_s` inchange perdrait
        # les suspects de ce depot, donc remettrait a zero la grace de deux ticks qui protege ses
        # verrous. Un depot non traite n'est pas un depot sans suspects.
        {tally, suspects, awaits} =
          Enum.reduce(repos, {Lease.zero_tally(), MapSet.new(), MapSet.new()}, fn repo,
                                                                                  {acc_t, acc_s,
                                                                                   acc_a} = acc ->
            repo_state = %{base | repo: repo}

            try do
              {t, s, a} = step_do_poll(repo_state, mode, pods)
              {Lease.merge_tally(acc_t, t), MapSet.union(acc_s, s), MapSet.union(acc_a, a)}
            rescue
              e -> repo_poll_crash(repo_state, e, acc)
            catch
              kind, reason -> repo_poll_crash(repo_state, {kind, reason}, acc)
            end
          end)

        # Arch net — FLEET-GLOBAL action on the UNIQUE arch pod, decided ONCE per tick on the
        # cross-repo union (inside the per-repo loop, the first repo would stamp the cooldown and
        # starve the union view: the logged backlog would lie). REGULAR ticks only: the cooldown is
        # time-based so kick-polls could not compress the CAP anymore, but the woken arch generates
        # the very webhooks that would re-evaluate this net at webhook rate for nothing (the label
        # set only changes on poll reads — evaluating between them is pure churn).
        base = if mode == :tick, do: maybe_rekick_arch(awaits, base), else: base

        # Desired-state pass of the main branch-protection (throttled per repo, regular ticks
        # only). Projecting the rule ONCE at onboarding and treating "already exist" as a blind
        # :ok leaves an imported repo's stale rule, or a card changed since, holding a main
        # protection out of line with the CURRENT jury — with nothing to say so.
        base = if mode == :tick, do: maybe_recheck_protection(base, repos), else: base

        # The CYCLE, measured AT ITS OWN SCALE — strictly distinct from `[:poller, :poll]`, which
        # is emitted PER REPO (every emission carries `repo:`). A distribution over `:poll` cannot
        # answer "how long does a full pass take": it describes one repo, and the number of repos
        # appears nowhere in it. Yet it is the duration of the PASS that decides whether a value
        # frozen at its start (a `base_sha`, a pod snapshot) can go stale before it ends.
        #
        # `started` is captured BEFORE `list_org_repos`, so the measurement covers everything a
        # pass does: discovery, the pod snapshot, the SERIAL fold of the R repos, and the two
        # fleet-global passes (arch net, protection recheck). Not just its visible part.
        :telemetry.execute(
          [:lcars_fleet, :pilot_poller, :cycle],
          %{duration_ms: elapsed_ms(started), repos: length(repos)},
          %{status: :ok, mode: mode, orgs: state.orgs}
        )

        {tally, %{base | orphan_lock_suspects: suspects, last_tally_errors: tally.errors}}

      {:error, reason} ->
        # A pass that fails at discovery IS a pass, and it has a duration. Dropping it would make
        # the cycle's p95 prettier than reality on exactly the case an operator watches — the same
        # blindness that capturing `started` after the slow call already avoided. `repos: 0` is not
        # filler: no repo was folded.
        :telemetry.execute(
          [:lcars_fleet, :pilot_poller, :cycle],
          %{duration_ms: elapsed_ms(started), repos: 0},
          %{status: :error, mode: mode, orgs: state.orgs}
        )

        handle_poll_error(state, {:discover_repos, reason}, started)
    end
  end

  # Throttled desired-state pass: every repo whose last recheck is older than the period
  # goes through the SAME projection point as onboarding (convergent protect_branch). A
  # failed reconcile logs warning and retries next period — the protection is a
  # desired-state, not a one-shot projection.
  defp maybe_recheck_protection(%__MODULE__{} = state, repos) do
    now = System.monotonic_time(:millisecond)

    due =
      Enum.filter(repos, fn repo ->
        now - Map.get(state.protection_rechecked, repo, now - @protection_recheck_ms - 1) >=
          @protection_recheck_ms
      end)

    reconciler =
      state.protection_reconciler ||
        (&Fleet.Project.Onboard.reconcile_main_protection/2)

    # ⚠ ON N'HORODATE QUE CE QU'ON A RECONCILIE. Pose sur TOUS les `due`, echecs compris, le tampon
    # renvoie pour une periode entiere un depot dont la reconciliation vient d'echouer — alors que
    # la seule chose qu'on sait de lui, c'est qu'on n'a pas su le lire. Un echec n'est pas un
    # travail fait, et le throttle existe pour espacer le
    # travail — pas pour espacer les retentatives d'un travail qui n'a pas eu lieu.
    reconciled =
      Enum.filter(due, fn repo ->
        case reconciler.(repo, state.forge_opts) do
          :ok ->
            true

          {:error, reason} ->
            Logger.warning(
              "Poller: main-protection reconcile #{repo} FAILED (#{inspect(reason)}) — " <>
                "NOT stamped, retried at the NEXT TICK (the rule may be out of line with the " <>
                "current jury, or the forge was unreadable)"
            )

            false
        end
      end)

    %{
      state
      | protection_rechecked:
          Enum.reduce(reconciled, state.protection_rechecked, &Map.put(&2, &1, now))
    }
  end

  # Une enumeration de pods en echec est DEUX choses a la fois : un fail-safe correct — on ne
  # reclame rien plutot que de deverrouiller a l'aveugle — et une panne potentiellement DURABLE,
  # pendant laquelle un `lcars-in-flight` survit indefiniment a son pod. Muette, elle est
  # indiscernable d'un tick qui n'a simplement rien a reclamer.
  #
  # ⚠ ON PARLE SUR LA TRANSITION, jamais par tick, et le RETABLISSEMENT s'annonce aussi : sans lui,
  # l'operateur qui a vu l'alerte ne peut pas distinguer resolu de mort.
  #
  # `:none` (kick) ne dit RIEN de la sante : un kick ne prend pas d'instantane, et le compter comme
  # un succes effacerait une panne en cours au premier webhook.
  defp note_pods_snapshot(%__MODULE__{} = state, :none), do: state

  defp note_pods_snapshot(%__MODULE__{} = state, {:error, reason}) do
    if state.pods_snapshot_ok? do
      Logger.warning(
        "Poller: pod enumeration FAILED reason=#{inspect(reason)} — nothing is reclaimed while " <>
          "this lasts (fail-safe), so an orphaned lock outlives its pod"
      )

      incident = state.incident_fun || (&Fleet.Pilot.IncidentRegistry.record_or_escalate/4)

      _ =
        try do
          # ⚠ LE SUJET N'EST PAS UNE ORG : il entre dans la CLE DE RECURRENCE, donc en nommer une
          # ferait changer la signature d'une panne identique des qu'un catalogue est active ou
          # reordonne — cooldown remis a zero, meme incident re-escalade comme neuf. Un spawner
          # injoignable est une panne de la BOITE ; le sujet ne route rien, il NOMME.
          incident.("pod_enumeration", "spawner", :spawner_unreachable,
            reason_detail: inspect(reason)
          )
        catch
          # never-stall: the incident rail OBSERVES the outage, it is never a condition of it.
          kind, why ->
            Logger.warning(
              "Poller: incident rail unavailable for pod enumeration " <>
                "(#{inspect(kind)} #{inspect(why)}) — the fail-safe stands, its escalation does not"
            )
        end
    end

    %{state | pods_snapshot_ok?: false}
  end

  defp note_pods_snapshot(%__MODULE__{} = state, _pods) do
    if not state.pods_snapshot_ok? do
      Logger.info("Poller: pod enumeration RECOVERED — orphaned-lock reclamation resumes")
    end

    %{state | pods_snapshot_ok?: true}
  end

  # DISCOVERY path only (`list_org_repos` KO = the forge itself is down/degraded): feeds
  # err_streak → backoff. The per-repo list failures go through `log_repo_list_error/3`
  # (no streak, no backoff).
  defp handle_poll_error(state, reason, started) do
    new_streak = state.err_streak + 1

    Logger.warning(
      "Poller: discovery error reason=#{inspect(reason)} streak=#{new_streak} " <>
        "(backoff arms the next tick)"
    )

    :telemetry.execute(
      [:lcars_fleet, :pilot_poller, :poll],
      %{duration_ms: elapsed_ms(started)},
      %{
        status: :error,
        repo: state.repo,
        error: inspect(reason),
        err_streak: new_streak
      }
    )

    {%{Lease.zero_tally() | errors: 1},
     %{
       state
       | error_count: state.error_count + 1,
         err_streak: new_streak,
         last_error: inspect(reason)
     }}
  end

  # ============================================================
  # STEP mode — assignee-driven reactor (the forge IS the state machine; this module is its reactor).
  # ============================================================

  defp step_do_poll(state, mode, pods) do
    started = System.monotonic_time()
    forge = step_forge_client(state)

    # ⚠ DISCOVERY IS NOT ADMISSION : le scan d'org dit ce qu'on REGARDE, jamais ce qu'on peut
    # SERVIR. Un depot arrive dans l'org sans avoir ete onboarde n'a pas de repertoire de projet, et
    # le rail le sert A MOITIE pour toujours — la route s'grave sur ses issues, puis chaque dispatch
    # degrade en signalant bruyamment son propre symptome, aucun ne nommant la cause.
    #
    # L'onboarding est un geste DELIBERE, et l'auto-provisionner sur decouverte ferait d'un `git
    # init` dans l'org le declencheur d'un clone — une politique que personne n'a choisie.
    if onboarded?(state.repo) do
      # ⚠ EFFACE ICI, sinon une memoire d'AFFICHAGE devient une memoire DEFINITIVE : un depot qui
      # repasserait « non onboarde » se tairait pour toute la vie du process.
      Process.delete({__MODULE__, :not_onboarded_logged, state.repo})
      step_do_poll_onboarded(state, mode, pods, started, forge)
    else
      not_onboarded_skip(state, repo_scoped_suspects(state))
    end
  end

  # UN PERMANENT QUE RIEN NE SONDE EST UN PERMANENT DE NOM. L'architecte est `lifetime_scope:
  # forever` ; assure sur des EVENEMENTS seulement, un redemarrage entre deux laisse le projet sans
  # arbitre, sans erreur ni escalade : un etat invisible.
  #
  # ICI, ET PRECISEMENT ICI : c'est le point ou le depot est connu ONBOARDE et NON PARQUE, les deux
  # sans un appel de forge de plus. Ticks reguliers seulement — un kick de webhook est un indice de
  # dispatch, et le reveil de l'arch produit justement ces webhooks.
  #
  # ⚠ CETTE BOUCLE NE PEUT PAS DIRE A QUI EST LE PROJET. Elle parcourt le SCAN D'ORG, et le garde
  # au-dessus prouve que le projet est installe sur cette MACHINE — jamais que l'humain qui fait
  # tourner cette fleet l'a demande, la racine des projets etant PARTAGEE. La question « est-ce le
  # notre » se tranche donc la ou vit le registre : `ensure_alive` garde ce que cette boite a EN
  # REGISTRE et ne cree rien.
  defp keep_architect(state) do
    keeper = state.architect_keeper || (&Fleet.Project.Architect.ensure_alive/2)
    _ = keeper.(state.repo, state.forge_opts)
    :ok
  end

  # Prior suspects REPO-SCOPED (the refs are repo-qualified precisely for this): the whole
  # cross-repo union let an error/kick branch resurrect suspects RESOLVED on other repos (grace
  # bypassed → reclaim in the registration window of a freshly re-spawned pod).
  # Le depot a leve : on le saute, on le DIT, et on garde ses suspects. L'incident est ouvert parce
  # que la cause est deterministe — un conflit pathologique se represente a chaque tick — et qu'un
  # depot definitivement non servi est exactement le genre de panne qu'une telemetrie de comptes ne
  # montre pas : les autres depots continuent, le total reste plausible.
  defp repo_poll_crash(state, reason, {acc_t, acc_s, acc_a}) do
    Logger.error(
      "Poller: repo=#{state.repo} RAISED during its poll (#{inspect(reason)}) — this repo is " <>
        "skipped for this tick, the others are NOT. The cause is usually deterministic (the same " <>
        "PR, the same file), so it will repeat until someone looks."
    )

    escalate = state.escalate_fun || (&Fleet.Pilot.IncidentRegistry.escalate_gated/5)

    _ =
      escalate.(
        :repo_poll_crash,
        state.repo,
        {:poll_raised, reason},
        "repo_poll_crash:#{state.repo}",
        state.forge_opts || []
      )

    {acc_t, MapSet.union(acc_s, repo_scoped_suspects(state)), acc_a}
  end

  defp repo_scoped_suspects(state),
    do: MapSet.filter(state.orphan_lock_suspects, fn {r, _type, _n} -> r == state.repo end)

  # The project's ops worktree on disk — what `BriefArtifact.physicalize` commits into. Its
  # ABSENCE is the mechanical signature of a repo that no onboarding verb ever touched: the
  # consumer already degrades on exactly this condition, in its own corner and without naming it.
  # `:require_onboarded` is a TEST-HERMETICITY lever, not an operator knob: the unit tests drive
  # fictional repos that have no project directory anywhere, so `config/test.exs` turns the gate
  # off in the same breath as `start_listener: false` and the stub launch backend. The dedicated
  # test turns it back on to pin the behaviour. In prod it is absent ⟹ true, and nothing in
  # `etc/fleet_v2.env.template` offers it — a door that only the hermetic baseline opens.
  defp onboarded?(repo) do
    if Application.get_env(:lcars_fleet, :pilot_require_onboarded, true),
      do: File.dir?(project_work_dir(repo)),
      else: true
  end

  defp project_work_dir(repo),
    do: Path.join(Fleet.Layout.ops_root(), Fleet.Layout.project_name(repo))

  # Meme forme que `parked_skip/2`, et logue UNE fois par depot : un cron de 30 s ne doit pas crier
  # a chaque tour, et un onboarding se fait souvent dans les minutes qui suivent le message.
  defp not_onboarded_skip(state, repo_prior) do
    # ⚠ « JAMAIS ONBOARDE » ET « LE SUBSTRAT A DISPARU » RENDAIENT LA MEME PHRASE, et le second est
    # une panne de la boite : la racine absente saute le rail pour TOUS les depots a la fois, la
    # flotte tourne a vide, et rien ne distingue « aucun travail » de « le sol a disparu ».
    # Le discriminant est la RACINE, pas le projet, et il ne coute rien sur le chemin du skip.
    present? = state.substrate_present_fun || fn -> File.dir?(Fleet.Layout.ops_root()) end

    if present?.() do
      unless Process.get({__MODULE__, :not_onboarded_logged, state.repo}) do
        Process.put({__MODULE__, :not_onboarded_logged, state.repo}, true)

        Logger.warning(
          "Poller: repo=#{state.repo} discovered in the org but NOT ONBOARDED (no ops at " <>
            "#{project_work_dir(state.repo)}) — step rail skipped. Serving it would engrave routes " <>
            "and dispatch without provenance or project doctrine. Onboard it " <>
            "(create / import / open / adopt) to bring it in."
        )
      end
    else
      substrate_gone(state)
    end

    {Lease.zero_tally(), repo_prior, MapSet.new()}
  end

  # LA RACINE DES FACES A DISPARU. Escalade en incident plutot qu'un warning de plus : c'est une
  # panne de substrat, pas une propriete d'un depot, et elle est INVISIBLE dans la telemetrie — des
  # comptes nuls y sont indistinguables d'une flotte au repos. Un `warning` par depot et par vie du
  # process ne survit pas a la nuit ; un incident est une issue durable (doctrine D1).
  #
  # Memorise par PROCESS, pas par depot : la racine est UNE, et crier une fois par depot ferait de
  # la panne un bruit proportionnel au nombre de projets.
  defp substrate_gone(state) do
    unless Process.get({__MODULE__, :substrate_gone_logged}) do
      Process.put({__MODULE__, :substrate_gone_logged}, true)

      root = Fleet.Layout.ops_root()

      Logger.error(
        "Poller: the ops root #{root} is ABSENT or unreadable — the step rail is skipped for " <>
          "EVERY repo, not just #{state.repo}. This is not an un-onboarded project: the substrate " <>
          "itself is gone (unmounted, permissions), and the fleet is running empty while the " <>
          "telemetry reports zero counts."
      )

      escalate = state.escalate_fun || (&Fleet.Pilot.IncidentRegistry.escalate_gated/5)

      _ =
        escalate.(
          :ops_root_missing,
          root,
          {:ops_root_absent, root},
          "ops_root_missing:#{root}",
          state.forge_opts || []
        )
    end

    :ok
  end

  defp step_do_poll_onboarded(state, mode, pods, started, forge) do
    repo_prior = repo_scoped_suspects(state)

    # Per-repo ceiling: we list ALL open items (in-flight included) to count the active
    # workflow_runs. We ALSO list the open PRs → the JUDGES are dispatched
    # via the PR's requested_reviewers (plus the issue assignee). decide skips the in-flight ones.
    # FORGE-SIDE multi-user scoping: SAME `assigned_by` filter for issues AND PRs (both go
    # through /issues?type=… on the ForgeClient side). The poller sees ONLY the items of ITS human → scoping lives in
    # ONE place (the list), decide/dispatch_review do not re-check ownership. Per-human ceiling.
    scoped_opts = Keyword.put(state.forge_opts, :assigned_by, state.my_human)

    with {:ok, issues} <- forge.list_open_issues(state.repo, scoped_opts),
         {:ok, pulls} <- forge.list_open_pulls(state.repo, scoped_opts) do
      # BL-6-30 — a PARKED project (open `[lcars-parked]` marker issue, read in the SAME listing
      # as everything else: zero added I/O, zero RAM state) closes the step rail for this repo.
      if parked?(issues) do
        parked_skip(state, repo_prior)
      else
        Process.delete({__MODULE__, :parked_logged, state.repo})
        if mode == :tick, do: keep_architect(state)
        step_do_poll_live(state, mode, started, issues, pulls, repo_prior, pods)
      end
    else
      {:error, reason} ->
        # Log + telemetry only: the per-repo error state is NOT threaded up (cross-tick error
        # counters live on the discovery path, `do_poll` — only DISCOVERY feeds
        # err_streak/backoff). Suspects: contribute THIS repo's prior subset unchanged (2-tick
        # grace preserved across a transient list failure — repo-scoped, so suspects resolved
        # on OTHER repos are not resurrected); awaits: unknown for this repo (nothing listed)
        # → empty.
        tally = log_repo_list_error(state, reason, started)
        {tally, repo_prior, MapSet.new()}
    end
  end

  defp parked?(issues),
    do: Enum.any?(issues, &Fleet.Forge.Protocol.parked_issue_title?(&1["title"]))

  # The full per-repo skip: no dispatch, no lease, no reclaim seeding, no awaits union.
  # Suspects pass through UNCHANGED (same stance as `:kick` — the 2-tick grace stays frozen,
  # reclaim resumes at unpark). The desired-state protection pass deliberately STILL runs
  # (`do_poll`, outside step_do_poll): a closed project keeping its forge floor is correct.
  # The log fires once per park (display-only pdict memory in the Poller singleton — unpark
  # clears it, a re-park logs again): a ~30s cron must not cry once per tick.
  defp parked_skip(state, repo_prior) do
    unless Process.get({__MODULE__, :parked_logged, state.repo}) do
      Process.put({__MODULE__, :parked_logged, state.repo}, true)

      Logger.info(
        "Poller: repo=#{state.repo} PARKED (marker issue) — step rail skipped until reopened"
      )
    end

    {Lease.zero_tally(), repo_prior, MapSet.new()}
  end

  # The LIVE per-repo pass (not parked).
  defp step_do_poll_live(state, mode, started, issues, pulls, repo_prior, pods) do
    forge = step_forge_client(state)

    pr_issue_ids = pulls_issue_ids(pulls)

    # Lock reconciliation BEFORE dispatch: an orphaned `lcars-in-flight` (pod dead without having
    # completed → reaped, but the label survives on the forge side) would block the brick FOREVER
    # (`dispatch_*` skips `:in_flight`). We reclaim it (2-tick grace) → the next tick re-dispatches.
    # Without this, a single pod stall wedges the pipe permanently. The DECISION lives in
    # `Reconciliation` (reads 5 seams, yields the set of suspects); the 2-tick grace (`prior_suspects`) and
    # the cross-repo union stay HERE (cross-tick state). We resolve the prod defaults of the seams at THIS site.
    reconciliation_seams = %Reconciliation.Seams{
      forge: forge,
      spawner: state.spawner || Fleet.Spawner,
      task_queue: state.task_queue || Fleet.TaskQueue,
      repo: state.repo,
      forge_opts: state.forge_opts
    }

    new_suspects =
      case mode do
        :tick ->
          Reconciliation.reconcile(
            issues,
            pulls,
            pr_issue_ids,
            repo_prior,
            reconciliation_seams,
            pods
          )

        :kick ->
          # DISPATCH-ONLY: the kick does NOT reclaim, seed or erase — strict passthrough of
          # the suspects (mirror of the error branch below). The 2-tick grace is calibrated
          # in REGULAR ticks (~30s): counting kicks would compress it to ~2s under the forge
          # traffic generated by the completion sequence itself → reclaim of the
          # lcars-in-flight lock inside the publication window → double dispatch/double spend.
          # A kick that SEEDED suspects would be the inverse bug (an orphan is confirmed by
          # the regular tick ≤30s later, at age <60s). Reclaim latency stays governed by
          # the regular tick, unchanged.
          repo_prior
      end

    # dispatch opts computed ONCE/tick (shared issues + pulls), not 2×.
    opts = step_dispatch_opts(state)

    # ⚠ L'ESCALADE POSE `awaits-arch` SUR L'ISSUE, et `dispatch_review` ne lit QUE les labels de la
    # PR : sans ce fil, le juge d'une PR dont l'issue attend l'arch est respawne a chaque tick.
    # L'ensemble est repo-QUALIFIE — les numeros d'issue se telescopent entre depots.
    awaits_arch_ids = awaits_arch_ids(issues)

    # BL-6-48 step 3, PR half. Same gesture as the line above, and for the same reason: the PR path
    # holds PULLS, not issues — yet the `wait/*` lives on the ISSUE (it is the ticket a human reads,
    # and it outlives its successive PRs). Without this threading, writing from the pulls would cost
    # a `issue_get` per skipped PR. The issues are already listed WITH their labels: the map is
    # free, exactly like `awaits_arch_ids`.
    pulls_opts =
      opts
      |> Keyword.put(:awaits_arch_ids, awaits_arch_ids)
      |> Keyword.put(:wait_labels, wait_labels(issues))

    tally =
      Lease.merge_tally(
        Lease.process_issues(issues, pr_issue_ids, opts, lease_seams(state)),
        step_process_pulls(pulls, pulls_opts)
      )

    duration_ms = elapsed_ms(started)

    # A successful tick = SILENT. This poll is a ~30s cron in a loop; logging every nominal pass
    # (most often dispatched=0, nothing to do) drowns the trace under hundreds of routine
    # lines. The metrics (duration, dispatched/skipped/errors) go to telemetry below;
    # poll failures are logged (handle_poll_error) and each per-item dispatch traces at its own
    # level. We log when it breaks, not when it runs.
    :telemetry.execute(
      [:lcars_fleet, :pilot_poller, :poll],
      %{duration_ms: duration_ms},
      Map.merge(tally, %{status: :ok, mode: :step, repo: state.repo})
    )

    # F-037 — per-item dispatch errors (broker enqueue KO, spawn KO) surface via `tally.errors` →
    # telemetry + `last_tally_errors` (aggregated by `do_poll`), NEVER as backoff: the forge is
    # UP (both lists succeeded), so slowing the whole fleet's poll would punish the wrong layer.
    # Only a DISCOVERY failure (do_poll) feeds `err_streak`.
    {tally, new_suspects, MapSet.new(awaits_arch_ids, &{state.repo, &1})}
  end

  # Per-repo list failure — DISTINCT from the discovery path (`handle_poll_error`): the forge is
  # UP (discovery succeeded this very poll), no backoff is armed and no streak exists on this
  # path — logging "streak=1" would perpetually suggest a backoff-in-progress that this policy
  # deliberately does not run here. Telemetry mirrors the log: no err_streak on this scope.
  defp log_repo_list_error(state, reason, started) do
    Logger.warning(
      "Poller: per-repo list failure repo=#{state.repo} reason=#{inspect(reason)} " <>
        "— no backoff (forge up, discovery succeeded)"
    )

    :telemetry.execute(
      [:lcars_fleet, :pilot_poller, :poll],
      %{duration_ms: elapsed_ms(started)},
      %{
        status: :error,
        scope: :repo_list,
        repo: state.repo,
        error: inspect(reason)
      }
    )

    %{Lease.zero_tally() | errors: 1}
  end

  # SET of issue numbers carrying `lcars-awaits-arch`. Derived from the `issues` ALREADY listed
  # by the tick (no extra forge call) → threaded to the pulls (`:awaits_arch_ids`) so that
  # `dispatch_review` skips the judge of a PR whose parent issue awaits the arch.
  defp awaits_arch_ids(issues) do
    for i <- issues, n = i["number"], awaits_arch?(i), into: MapSet.new(), do: n
  end

  # G4 — LE FILET awaits-arch. Le premier reveil d'une escalade est immediat ; s'il est PERDU, la
  # verite reste le label sur la forge, relu a chaque tick, et ce filet en RE-DERIVE un reveil.
  #
  # ⚠ IL NE FAIT QUE POUSSER LE SAS : le label reste libere par l'humain, jamais par nous.
  #
  # ⚠ LES DEFAUTS SE RESOLVENT ICI, jamais par un garde sur nil : la prod n'injecte PAS les seams,
  # donc un garde qui saute quand le seam est nil transformerait ce rail en no-op silencieux.
  # Un resultat qui n'a RIEN envoye (`:busy`, echec d'enqueue) n'estampille pas le cooldown.
  defp maybe_rekick_arch(awaits_ids, %__MODULE__{} = state) do
    now = System.monotonic_time(:millisecond)

    if awaits_rekick?(MapSet.size(awaits_ids), state.last_arch_rekick_at, now) do
      spawner = state.spawner || Fleet.Spawner
      task_queue = state.task_queue || Fleet.TaskQueue

      case Fleet.Pilot.ArchWake.offer_then_wake(task_queue, spawner, awaits_ids, "net") do
        sent when sent in [:offered, :woken_pending] ->
          Logger.info(
            "Poller: #{MapSet.size(awaits_ids)} issue(s) awaits-arch (fleet-wide) → net #{sent} " <>
              "(cooldown #{div(@awaits_rekick_cooldown_ms, 1000)}s armed)"
          )

          %{state | last_arch_rekick_at: now}

        # :busy / :wake_unreached / enqueue error — nothing left, so no cooldown is armed: the
        # next eligible tick retries (the durable forge label + any enqueued mandate persist).
        _no_signal_sent ->
          state
      end
    else
      state
    end
  end

  # Enqueue ONE escalation as an arbitration mandate. Stable pick = the smallest `{repo, n}` (deterministic
  # across ticks; not time-ordered, but the arch drains them one-by-one WITH the human — order is not
  # load-bearing). The mandate POINTS to the issue (the arch reads it via its forge tools); the `WorkItem`
  # has no `repo` field → repo+number travel in `metadata` (the ArchInboxConsumer correlates on it to drain
  # the label at `submit_result`). A failed enqueue loses only latency (the label persists → re-offered).
  @doc false
  # PURE net decision: at least ONE issue awaits the arch AND the last SENT kick is older than
  # the cooldown (nil = never → fire on the first eligible tick). Exposed (test) — the
  # computation is the load-bearing core (the wake itself is a seam delegation via ArchWake).
  @spec awaits_rekick?(non_neg_integer(), integer() | nil, integer()) :: boolean()
  def awaits_rekick?(awaits_size, last_kick_at, now_ms)
      when is_integer(awaits_size) and is_integer(now_ms) do
    awaits_size > 0 and
      (is_nil(last_kick_at) or now_ms - last_kick_at >= @awaits_rekick_cooldown_ms)
  end

  defp awaits_arch?(item) do
    @awaits_arch in Payload.label_names(item)
  end

  # Issues carrying an open fleet PR (`lcars/issue-N-role`) = workflow_runs in JUDGE phase:
  # the producer is done, the rest is dispatched via the pulls -> the issue path SKIPS them
  # (otherwise the poller would re-spawn the producer, still assigned).
  defp pulls_issue_ids(pulls) do
    # C-05: the single Fleet-PR selector (ForgeProtocol); local projection = the SET of issue numbers.
    pulls
    |> Fleet.Forge.Protocol.fleet_prs_by_issue()
    |> Enum.map(fn {n, _pr} -> n end)
    |> MapSet.new()
  end

  # PR-driven path: each open PR with a requested review → dispatch the judge.
  # Not guarded by the lease (the judges of an ALREADY active workflow_run must advance; the lease bounds
  # only the ENTRY of new workflow_runs, on the issues side).
  defp step_process_pulls(pulls, opts) do
    wait_labels = Keyword.get(opts, :wait_labels, %{})

    # Same admission order as the issues rail, by the ticket the PR carries. Not decorative since
    # the per-role pre-flight can refuse a judge mid-tick: whoever is walked first gets the seat,
    # so the walk order is a decision. Ascending id, or the forge's "most recently touched" would
    # decide it — and it would decide it differently on the two rails.
    pulls
    |> Enum.sort_by(&pr_issue_number/1)
    |> Enum.reduce(Lease.zero_tally(), fn pr, acc ->
      # The issue number comes from the feature-branch name (`lcars/issue-N-<role>`): zero calls. A
      # foreign PR does not parse → `nil` → the wait convergence does nothing, which is the correct
      # behaviour and not a side effect: it is not our ticket.
      issue_n = pr_issue_number(pr)

      # Through the funnel, exactly like the issues rail. `started?` is dropped here and that is the
      # asymmetry stated rather than hidden: the lease bounds the ENTRY of new workflow_runs, and a
      # judge of an already-active run is not an entry.
      {acc2, _started?} =
        Admission.admit(
          fn -> StepDispatcher.dispatch_review(pr, opts) end,
          opts,
          issue_n,
          Map.get(wait_labels, issue_n),
          acc
        )

      acc2
    end)
  end

  # `issue → wait/*` for the issues carrying one. Derived from the issues ALREADY listed by the
  # tick (zero forge call), threaded to the pulls — exact twin of `awaits_arch_ids/1`.
  defp wait_labels(issues) do
    # `Admission.current_wait/1` and not a local scan: "what is this ticket waiting for" is a
    # transverse question, and answering it twice is how the two rails earned two dialects.
    for i <- issues,
        n = i["number"],
        label = Admission.current_wait(i),
        into: %{},
        do: {n, label}
  end

  defp pr_issue_number(pr) do
    case Fleet.Forge.Protocol.parse_feature_branch(Payload.head_ref(pr) || "") do
      {:ok, {n, _role}} -> n
      _ -> nil
    end
  end

  # Hardened boundary to `Lease` (per-repo ceiling): the 5 authorized reads, prod defaults
  # resolved HERE (same rule as `Reconciliation.Seams`: we resolve at the construction site).
  defp lease_seams(state) do
    %Lease.Seams{
      forge: step_forge_client(state),
      repo: state.repo,
      forge_opts: state.forge_opts,
      workflow_map_loader: state.workflow_map_loader || Fleet.Workflow.Loader,
      incident_fun: state.incident_fun || (&Fleet.Pilot.IncidentRegistry.record_or_escalate/4)
    }
  end

  # Builds the opts for StepDispatcher.dispatch_issue. The seams
  # (loader/spawner/task_queue) are injected ONLY if they are set on the
  # state — otherwise StepDispatcher applies its real defaults (passing nil
  # would overwrite the default).
  # `:task_queue` is carried by the state (resolved at the call site of `Reconciliation.reconcile`) and MUST
  # be passed here, otherwise StepDispatcher falls back to the global `Fleet.TaskQueue` for the brief enqueue
  # (broker seam not honored on the dispatch side).
  defp step_dispatch_opts(state) do
    [
      repo: state.repo,
      forge_client: step_forge_client(state),
      forge_opts: state.forge_opts
    ]
    |> Opts.maybe_put(:loader, state.loader)
    # `workflow_map_role` (dispatch) loads the route's workflow_map → it needs the WORKFLOW_MAP loader (as a
    # load!/1 function). Live: nil → default `Fleet.Workflow.Loader.load!` (priv). Test: derived from the stub
    # module. (Distinct from `:loader` = cap-profiles.)
    |> Opts.maybe_put(:workflow_map_loader, workflow_map_loader_fun(state))
    |> Opts.maybe_put(:spawner, state.spawner)
    |> Opts.maybe_put(:task_queue, state.task_queue)
    # Threaded down to `dispatch_issue`: only nil falls back to the real default (the real `WakeRecovery.wake/3`).
    |> Opts.maybe_put(:wake_recovery, state.wake_recovery)
  end

  defp workflow_map_loader_fun(%__MODULE__{workflow_map_loader: nil}), do: nil

  defp workflow_map_loader_fun(%__MODULE__{workflow_map_loader: cl}),
    do: fn name -> cl.load!(name) end

  defp step_forge_client(%__MODULE__{forge_client_override: nil}), do: Fleet.Forge.Client
  defp step_forge_client(%__MODULE__{forge_client_override: fc}), do: fc

  defp elapsed_ms(started_native) do
    System.convert_time_unit(
      System.monotonic_time() - started_native,
      :native,
      :millisecond
    )
  end
end
