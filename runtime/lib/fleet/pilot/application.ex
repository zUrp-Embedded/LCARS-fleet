defmodule Fleet.Pilot.Application do
  require Logger

  alias Fleet.Pilot.IncidentConsumer
  alias Fleet.Pilot.StepRunConsumer
  alias Fleet.Workflow.Loader

  @moduledoc """
  Domain supervisor (`Application`, the name every domain gives its supervisor module).

  Supervisor for the pilot domain — **STEP mode only** (the forge IS the state machine).

  Starts, if `:pilot_step_dispatch?` is configured (`config/runtime.exs` from the env) and the forge
  `base_url` resolves, the processes of the forge-state-machine rail:

    * `Fleet.Pilot.Poller` (step mode) — **MULTI-PROJECT**: DISCOVERS the repos of every catalogue
      org by org-membership (`list_org_repos`, no hard-coded repo), dispatches the **assigned
      issues** (assignee=human) to the spawn of the route's role (`StepDispatcher`).
    * `Fleet.Pilot.StepRunConsumer` — Bus consumer: on `pod.completed`, runs the **end-of-step-run**
      (publish of the git-native deliverable → system push → PR open → merge). Without it, the chain
      does not advance past the producer spawn.
    * `Task.Supervisor` (`StepRunConsumer.task_supervisor/0`) — offload of the step_run completion: the
      `git push` ≤30s does not block the `StepRunConsumer` singleton. Started BEFORE the StepRunConsumer (which refers to it).
    * `Fleet.Pilot.IncidentConsumer` (+ its `Task.Supervisor`) — Bus consumer of the `action: incident`
      events of the routing table (seven types, four sources) → `IncidentRegistry`. Concern distinct from the end-of-step-run
      (isolated blast-radius: a burst of failures does not share the StepRunConsumer's mailbox).
    * `Fleet.Pilot.PollerTelemetry` — the attachment of `[:lcars_fleet, :pilot_poller, :poll]`. First child
      of the rail because it measures the rail: without it every duration the poller emits is
      computed and dropped (BL-6-40 Ph. 0).
  """

  use Supervisor

  # A BLACKOUT, not a bad figure: the verdict only falls when the WHOLE observed window failed, and
  # the window holds at least this many samples. Deliberately small — at one cycle per poll interval
  # three consecutive total failures is already a rail that has not advanced for a minute and a half
  # — but never one: readiness is what an operator consults when things go wrong, and a probe that
  # flickers on a single transient 500 is one they learn to ignore.
  @poll_blackout_window 3

  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(init_arg \\ []) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl Supervisor
  def init(_init_arg) do
    # CI-11: MCP brief writes require the ops serializer outside step mode too.
    children = [forge_finch_spec()] ++ ops_object_sync_child() ++ step_children()

    # Children resolve collaborators by name, so one-for-one recovery is sufficient.
    opts = [
      strategy: :one_for_one,
      max_restarts: 3,
      max_seconds: 60
    ]

    Supervisor.init(children, opts)
  end

  # Work/ops write serializer (CI-11) — always-on in prod, OFF in test (hermeticity, cf. init).
  defp ops_object_sync_child do
    if Application.get_env(:lcars_fleet, :pilot_start_ops_object_sync, true),
      do: [Fleet.Workflow.OpsObjectSync],
      else: []
  end

  @doc """
  The ForgeClient's Finch pool child spec.

  The shape lives in `Fleet.Forge`, next to the pool's NAME: the pilot is where it is first needed,
  not what it belongs to, and held here the pool is unstartable by anything that does not depend on
  the pilot.
  """
  @spec forge_finch_spec() :: tuple()
  defdelegate forge_finch_spec, to: Fleet.Forge, as: :finch_spec

  @doc """
  Liveness status of the forge-state-machine step rail, for readiness. fleet_pilot
  owns the rail topology → it is the one that knows whether the singletons are alive (fleet_api only
  asks, no MCP process name leaks into the surface).

    * `{:inactive, _}`    — `:pilot_step_dispatch?` off (rail deliberately absent, expected outside prod-step).
    * `{:operational, _}` — Poller + StepRunConsumer alive.
    * `{:degraded, _}`    — step enabled and EITHER ≥1 singleton dead, OR the last cycle discovered
      repositories and served NONE (`serving?/1` — nothing can advance), OR every poll of the observed
      window failed → **hollow-green caught** (the daemon runs but the forge rail no longer
      advances).

  ## What this verdict catches, and what it deliberately does not

  The two health keys are part of the PREDICATE, not just of the detail. Excluded from it — the
  natural shape, since they are the only non-boolean keys — no state of the polls could ever move
  the verdict: a forge unreachable, a dead DNS, an expired token, every cause that fails 100 % of
  the polls WITHOUT killing a process, would read `operational` while not one ticket advanced. A
  probe built to reveal that gap would be containing it in a field.

  It is a BLACKOUT that flips the verdict, not a bad figure: the whole observed window failed, over
  at least #{@poll_blackout_window} samples. Anything narrower would make readiness — the instrument an operator
  consults when things go wrong — flicker on one transient 500.

  Consequently it still says `operational` for: polls that are SLOW but succeed (the figures are in
  the detail, and no defensible threshold exists for a fleet whose repo count is unknown here); a
  PARTIAL failure, even a large one (one repo of twelve permanently broken is a repo-level fact, not
  a rail-level one); and `:no_data`, which cannot be told apart from a fleet that has just booted —
  a poller alive that never polls at all is NOT caught here.
  """
  @spec step_status() :: {:inactive | :operational | :degraded, map()}
  def step_status do
    if Application.get_env(:lcars_fleet, :pilot_step_dispatch?, false) do
      detail =
        Map.new(step_rail_processes(), fn {key, name} ->
          {key, is_pid(Process.whereis(name))}
        end)

      # ⚠ LE RAIL NOMME DANS LA READINESS DOIT ETRE LE RAIL MESURE. Sonder deux noms pendant que
      # d'autres processus essentiels sont morts rend un vert CREUX — d'ou une liste unique,
      # verrouillee sur les enfants reellement demarres par un test de derive.
      #
      # Et la SANTE des passes a cote de la liste des vivants : un rail dont tous les processus sont
      # debout mais dont les passes prennent quarante secondes est « operationnel » et ne va pas bien.
      #
      # ⚠ LA CLE S'APPELLE `repo_poll` ET PAS `tick`, parce que la mesure porte sur UN DEPOT et pas
      # sur un cycle : l'evenement est emis une fois PAR DEPOT. Un nom comme `tick` affirmerait une
      # portee que le mecanisme n'a pas, et une mesure se lit de travers dessus (mesure). Le cout
      # d'un CYCLE n'est pas mesure ici, et aucun nom ne doit le suggerer.
      #
      # Deux echelles, deux cles, JAMAIS une moyenne des deux : `poll_cycle` est celle a lire pour
      # savoir si une valeur figee en debut de passe peut se perimer avant la fin — `repo_poll` ne
      # peut pas y repondre, il ignore combien de depots existent.
      detail =
        detail
        |> Map.put(:repo_poll, repo_poll_health())
        |> Map.put(:poll_cycle, poll_cycle_health())

      if rail_healthy?(detail),
        do: {:operational, detail},
        else: {:degraded, detail}
    else
      {:inactive, %{note: "step_dispatch? off"}}
    end
  end

  # THE PREDICATE OF THE VERDICT, and it CLASSIFIES rather than excluding. An exclusion list —
  # `key in [:repo_poll, :poll_cycle] or up?` — lets the two health keys through unconditionally.
  # Deleting such a list changes nothing either: every value those keys can take (a map, `:no_data`,
  # `:unavailable`) is truthy. Only a real classification answers, which is why `key_healthy?/1`
  # has a clause per shape.
  defp rail_healthy?(detail), do: Enum.all?(detail, &key_healthy?/1)

  # A process key is a boolean: alive or the rail is degraded. Unchanged, and it still wins — a dead
  # singleton is degraded whatever the polls say.
  # DEUX QUESTIONS SUR LE MEME CYCLE : est-ce que les passes REUSSISSENT, et est-ce qu'elles ont
  # quelque chose a servir. La seconde ne se lit sur aucune autre cle — `repo_poll` ignore combien
  # de depots existent, et un depot ecarte rend le meme tally vide qu'un depot servi qui n'avait
  # rien a faire.
  defp key_healthy?({:poll_cycle, health}),
    do: polls_healthy?(health) and serving?(health)

  defp key_healthy?({:repo_poll, health}), do: polls_healthy?(health)

  defp key_healthy?({_key, up?}), do: up?

  @doc """
  SERVING — `false` quand le poller DECOUVRE des depots et n'en sert AUCUN — le rail ne peut rien faire
  avancer, quelle que soit la sante de ses passes.

  MESURE, sur un banc : deux heures, 268 cycles, zero erreur, readiness `operational`, et le seul
  depot de l'org ecarte a chaque tour (`NOT ONBOARDED … step rail skipped`). Une flotte qui ne PEUT
  rien produire se lisait comme une flotte au repos, et la difference ne vivait que dans un warning
  emis UNE fois par depot et par vie du process.

  LA BORNE EST « AUCUN », ET C'EST DELIBERE. Un depot non onboarde a cote d'autres qui le sont est
  un etat NORMAL — l'humain onboarde quand il veut, et crier a chaque depot en attente ferait de
  cette sonde un bruit qu'on apprend a ignorer. Ce qui est signale est le cas ou le compte des
  servis tombe a zero alors que des depots existent : la, aucun ticket ne peut avancer.

  Vrai par defaut sur toute forme inattendue, comme `polls_healthy?/1` : une sonde qui ne sait pas
  n'accuse pas.
  """
  @spec serving?(term()) :: boolean()
  def serving?(%{last_repos: repos, last_served: 0}) when is_integer(repos) and repos > 0,
    do: false

  def serving?(_other), do: true

  @doc false
  # Verdict on ONE health summary. Public for its test: the shapes it must classify come from
  # `PollerTelemetry`, and building the real ones through `step_status/0` would need the whole rail
  # up plus a saturated telemeter — the fixture would stop discriminating (same verdict both sides).
  # Same motive as `step_rail_processes/0` right below.
  #
  #   * `:no_data`     — healthy. Before the first poll there is nothing to judge, and this shape is
  #     INDISTINGUISHABLE from a poller that never polls: no timestamp here says which. Written
  #     limit, not an oversight.
  #   * `:unavailable` — healthy. The telemeter did not answer within the call timeout. Readiness
  #     must not fall because of its OWN instrument (same reason as the two `catch` clauses below),
  #     and the case where that instrument is DEAD is already carried by its own process key
  #     `poller_telemetry` — falling here would judge the rail on a timeout of the gauge.
  #   * a summary   — degraded only on a BLACKOUT: every sample of the window in error, window at
  #     least `@poll_blackout_window`. `stats/0` tallies errors by scope (a map), `cycle_stats/0`
  #     as a count (an integer); both are compared against the SAME window they came from.
  @spec polls_healthy?(term()) :: boolean()
  def polls_healthy?(:no_data), do: true
  def polls_healthy?(:unavailable), do: true

  def polls_healthy?(%{errors: errors, window: window}),
    do: not blackout?(error_count(errors), window)

  # Any shape this module does not know is not a verdict. Readiness stays readable rather than
  # calling a rail degraded on a summary it failed to read.
  def polls_healthy?(_other), do: true

  defp error_count(errors) when is_map(errors), do: errors |> Map.values() |> Enum.sum()
  defp error_count(errors) when is_integer(errors), do: errors
  defp error_count(_), do: 0

  defp blackout?(errors, window)
       when is_integer(window) and window >= @poll_blackout_window and errors >= window,
       do: true

  defp blackout?(_errors, _window), do: false

  # Health summary of the PER-REPO polls, or `:no_data` before the first one. TOTAL by obligation:
  # readiness is what an operator consults when things go wrong, so it must never fall because of
  # its own instrument. A dead telemeter yields `:unavailable` and the rail stays readable.
  defp repo_poll_health do
    Fleet.Pilot.PollerTelemetry.stats()
  catch
    :exit, _ -> :unavailable
  end

  # Health summary of the whole PASS. Same totality as above, and for the same reason.
  defp poll_cycle_health do
    Fleet.Pilot.PollerTelemetry.cycle_stats()
  catch
    :exit, _ -> :unavailable
  end

  @doc false
  # The registered names of the STEP rail's essential processes — the readiness DEFINITION owned HERE,
  # beside their single start site `step_children!`. EVERY process `step_children!` starts must appear
  # here (a rail with any of them dead is degraded, not a hollow "operational"); the drift test
  # `step_rail_processes ⇔ step_children!` fails if a new child is added there but not here.
  @spec step_rail_processes() :: list()
  def step_rail_processes do
    [
      # The instrument is part of the rail's readiness, not an accessory: a rail running with its
      # telemetry dead is a rail nobody can measure, which is the exact state BL-6-40 named. Better
      # `:degraded` and visible than `:operational` and blind.
      poller_telemetry: Fleet.Pilot.PollerTelemetry,
      poller: Fleet.Pilot.Poller,
      step_run_consumer: StepRunConsumer,
      step_run_task_supervisor: StepRunConsumer.task_supervisor(),
      incident_registry: Fleet.Pilot.IncidentRegistry,
      incident_consumer: IncidentConsumer,
      incident_task_supervisor: IncidentConsumer.task_supervisor(),
      worktree_sync: Fleet.Project.WorktreeSync,
      arch_feed: Fleet.Pilot.ArchFeed
    ]
  end

  # Processes of the STEP rail (the forge IS the state machine). Started iff `:pilot_step_dispatch?` is
  # true. `[]` if `:pilot_step_dispatch?` absent/false (deliberately inert app — test hermeticity).
  #
  # If `:pilot_step_dispatch?` is TRUE but the essential config does not resolve, we do NOT silently fall back
  # to `[]` (that would start the app "green" without Poller/StepRunConsumer → forge rail dead, zero
  # crash, zero log). The operator ASKED for step mode → incomplete config = broken deploy →
  # fail-loud at boot.
  defp step_children do
    if Application.get_env(:lcars_fleet, :pilot_step_dispatch?, false) do
      step_children!()
    else
      []
    end
  end

  @doc false
  # Test seam: exposes the rail child-specs WITHOUT starting the supervisor (which would register the
  # singletons under their global names → conflicts / parasitic boot). Used to verify the fail-loud guard.
  @spec step_children_for_test() :: list()
  def step_children_for_test, do: step_children()

  # MULTI-PROJECT: no mandatory repo nor remote frozen at boot — the Poller DISCOVERS its repos
  # by org-membership (`list_org_repos` on every catalogue org) and the StepRunConsumer derives the repo+remote
  # PER-STEP-RUN from the event. The essential config that remains = the forge `base_url`: without it, neither
  # discovery (`list_org_repos`) nor push (per-step-run remote) work → dead rail. This is the
  # fail-loud guard, aimed at the real thing.
  defp step_children! do
    unless forge_base_url() do
      raise "pilot: :pilot_step_dispatch? enabled but the forge base_url is absent (config :lcars_fleet, " <>
              ":forge[:base_url] / FORGE_BASE_URL) — the Poller cannot DISCOVER its projects " <>
              "(list_org_repos) nor can the StepRunConsumer derive the push remote. Deploy broken, fail-loud."
    end

    # Publish the workflow catalogue IMAGE first: the two guards below — and every
    # runtime consumer after them — then read what was just proved, never the live
    # disk (a post-boot catalogue edit is inert until restart). Missing, empty or
    # invalid catalogue → raise HERE, same dead-man's-switch as the base_url guard.
    Loader.publish_image!()

    validate_card_juries!()
    validate_card_steps!()
    validate_structural_roles!()
    require_signer_tokens!()
    validate_workshop_card!()
    validate_default_card_loads!()

    # The verdict wire schemas (gate-decision envelope + findings machine payload)
    # are EXECUTED on every ingest by Verdict.gate_decision/1 / Verdict.take_findings/1 —
    # resolved here once, fail-loud: a broken deploy artifact refuses at rail boot instead
    # of crashing the StepRunConsumer singleton on the first verdict.
    Fleet.Pilot.StepRunConsumer.Verdict.load_schema!()

    interval = Application.get_env(:lcars_fleet, :pilot_poll_interval_ms, 30_000)

    [
      # The poller's telemetry, ATTACHED (BL-6-40 Phase 0). Started BEFORE the Poller so no tick is
      # emitted into the void, and it is the FIRST child of the rail because it measures the rail:
      # the poller emits its durations whether or not anything listens, so without this child every
      # one of them is computed and dropped. Nothing else in BL-6-40 is provable until this exists.
      Fleet.Pilot.PollerTelemetry,
      # Task supervisor for the offload of step_run completion (the ≤30s git push of the
      # StepRunConsumer does not block the singleton). Started BEFORE the StepRunConsumer (which refers to it).
      # max_children: bounds the burst (cascade of pod.completed -> N concurrent forge pushes =
      # thundering herd). Beyond -> {:error, :max_children}, handled fail-loud by offload_async.
      {Task.Supervisor, name: StepRunConsumer.task_supervisor(), max_children: 16},
      # Persistent memory of system incidents (resilient owner). Consumed by WakeRecovery
      # (kick_gatekeeper / safe_wake) AND by the IncidentConsumer (`*.failed` events). The truth lives
      # in the local WAL (written first, crash-survivable); the forge is the ASYNC cross-machine
      # backing-store. Forge unreachable at boot → WAL only, no crash: the sync re-schedules itself
      # (`:sync_forge` retry, error logged at threshold) and catches up when the forge returns.
      Fleet.Pilot.IncidentRegistry,
      # Bus consumer of the `action: incident` events of the routing table → IncidentRegistry.
      # Its Task.Supervisor (offload of the registry's forge writes) started BEFORE it (it refers to it). Separate from
      # the StepRunConsumer: distinct concern, the failure burst does not share the completion's mailbox.
      {Task.Supervisor, name: IncidentConsumer.task_supervisor(), max_children: 16},
      {IncidentConsumer, runner: &IncidentConsumer.offload_async/1},
      # Serializer that aligns the local clone after merge: projects the merged branch onto the
      # FACE's worktree (`main` → code face, `ops` → ops face). Started BEFORE Poller + StepRunConsumer — its two merge triggers
      # (`promote_pr` / `StepRunCompleter.promote`) — so it serializes their potentially concurrent
      # alignments (one `git` at a time per worktree, against index corruption).
      Fleet.Project.WorktreeSync,
      # The architects' per-project activity feed (Bus consumer → fleet.feed in each arch pod_dir +
      # the single informational wake on the :delivered unlock). Rides the step rail: its lines ARE
      # step milestones — same lifecycle, hermetic in tests for free (step off).
      Fleet.Pilot.ArchFeed,
      # Neither `:repo` to the Poller (org-membership discovery), nor `:repo`/`:remote` to the StepRunConsumer (per-step-run).
      # The routing lives in scoped labels `wfmap/*`+`stage/*` (engraved by `post_route`); the Poller reads them (state-machine).
      # subscribe_gitea: the webhook accelerates the tick (a hint; the poll remains the truth).
      {Fleet.Pilot.Poller, interval_ms: interval, subscribe_gitea: true},
      {StepRunConsumer, forge_opts: [], step_run_runner: &StepRunConsumer.offload_async/2}
    ]
  end

  # F-C061 (jury own-goal, re-seated on the CARDS) — the jury lives in each workflow map
  # (`spec.jury`, schema-required; the card governs the judgment layer, no engine config).
  # The schema guards the SHAPE but not absurd CONTENT: a non-role login in a card's jury
  # would be LAID on PRs (`request_reviews_step`) and bumped into `required_approvals`, then
  # WEDGE at dispatch (no cap-profile → silent `:no_role`). We validate at boot that EVERY
  # jury role of EVERY canon card resolves to a `brief_kind: judge` cap-profile — a jury
  # that can't judge = a broken canon, fail-loud HERE, not a silent wedge on the first PR.
  # (Symmetric to the read-frontier filter in `StepDispatcher.dispatch_review`, which
  # restricts the forge-sourced reviewer set to the card's jury: this guards the canon
  # side, that guards the forge side.)
  # The enumeration is the BANG form: a missing root or an empty catalogue would make
  # both card guards vacuously true (readiness green with zero loadable card, first
  # route raises far from the deploy fault) — refused HERE at rail boot, same
  # dead-man's-switch contract as the base_url guard above.
  # The two STRUCTURAL roles of the single-brick model — the one that codes the brick, the one that
  # signs the merge — resolved from the catalogue by capability at rail boot. Same dead-man's-switch
  # as the two card guards above: a catalogue naming neither would otherwise reach readiness GREEN
  # and die at the first dispatch, far from the deploy fault. `Fleet.Project.Roles` carries the
  # resolution and the refusal messages; here we only make it happen before readiness.
  # (No log line: this module has none, and the resolution is not a milestone — its FAILURE is, and
  # the raise carries it. `Fleet.Project.Roles` remains the place to ask who they are.)
  @doc """
  The catalogue's card + structural-role checks, off the supervision path — for the standalone
  verifier. Runs EXACTLY what `start_link/1` runs at rail boot, in the same order and through the
  same functions: publish the workflow image, then the jury/step/structural guards. It lives HERE,
  beside `step_children!/0`, so the boot and the verifier share ONE sequence — the wall
  `boot.verifier_covers_rail` reads both bodies and refuses a guard the boot plays that the
  verifier does not (the reverse is tolerated: an extra guard in the verifier is conservative).
  Nothing in the boundary pins it here (`Fleet.Workflow` is a dep of the OTP root too).

  Raises on the first broken card or unresolvable structural role, same as boot; the verifier wraps
  the raise into a finding.
  """
  # ⚠ CETTE SEQUENCE ET CELLE DU BOOT JOUENT LES MEMES GARDES, ET LE `@doc` AU-DESSUS DIT
  # « EXACTLY » (6-008). Une garde presente au boot et absente ici laisse un verificateur VERT
  # preceder un boot ROUGE — le contraire exact de son objet.
  #
  # RIEN DANS LE CODE NE LIE LES DEUX SEQUENCES : ce qui tient l'equivalence est le check
  # `boot.verifier_covers_rail` de `mix lcars.contracts.check`, qui lit les DEUX listes a l'AST et
  # refuse la divergence. Ajouter une garde d'un cote sans l'ajouter de l'autre fait rougir le
  # gate, au lieu de rendre la phrase du `@doc` fausse en silence.
  # (Perimetre : les gardes de CATALOGUE, la famille `validate_*!`. Une garde de CONTENEUR —
  # `require_signer_tokens!`, credentials sur disque — reste au boot seul : ce verificateur est
  # tokenless par construction, cf. son commentaire.)
  @spec verify_cards_and_roles!(keyword()) :: :ok
  def verify_cards_and_roles!(opts \\ []) do
    Loader.publish_image!()
    validate_card_juries!(opts)
    validate_card_steps!(opts)
    validate_structural_roles!()
    validate_workshop_card!(opts)
    validate_default_card_loads!(opts)
    :ok
  end

  # ── The catalogue guards live with the catalogue (`Fleet.Workflow.CatalogueGuards`, beside
  # `CardRoles`); the structural roles with `Fleet.Project.Roles`. Re-exported here, `@doc false`,
  # for two reasons: the boot sequence (`step_children!/0`) and the standalone verifier
  # (`verify_cards_and_roles!/1`) read as ONE list of bare `validate_*!` calls that the wall
  # `boot.verifier_covers_rail` compares, and the guards' witnesses address the boot seam here.
  @doc false
  @spec validate_card_juries!(keyword()) :: :ok
  defdelegate validate_card_juries!(opts \\ []), to: Fleet.Workflow.CatalogueGuards
  @doc false
  @spec validate_workshop_card!(keyword()) :: :ok
  defdelegate validate_workshop_card!(opts \\ []), to: Fleet.Workflow.CatalogueGuards
  @doc false
  @spec validate_default_card_loads!(keyword()) :: :ok
  defdelegate validate_default_card_loads!(opts \\ []), to: Fleet.Workflow.CatalogueGuards
  @doc false
  @spec validate_card_steps!(keyword()) :: :ok
  defdelegate validate_card_steps!(opts \\ []), to: Fleet.Workflow.CatalogueGuards
  @doc false
  @spec validate_structural_roles!() :: :ok
  defdelegate validate_structural_roles!(), to: Fleet.Project.Roles

  # ⚠ UN CONTENEUR QUI NE PEUT PAS SIGNER COMME SES SIGNATAIRES REFUSE LA READINESS — il ne demarre
  # pas verte pour mourir des mois plus tard. Le signataire suivant la FONCTION, un jeton manquant
  # se manifesterait sinon a l'acte le plus terminal du chemin le plus rare : le defaut qui attend
  # le pire moment.
  #
  # `require_`, ET PAS `validate_` : le nom EST la declaration. La famille `validate_*!` est la
  # sequence de garde d'un CATALOGUE, rejouee par un verificateur autonome qui est SANS JETON par
  # design — y jouer ce garde-ci refuserait des catalogues valides pour une question de credential.
  # Un garde de CONTENEUR ne porte donc pas le nom de la famille.
  # ⚠ CE GARDE N'A PAS LA MEME PORTEE QUE SA LIGNE LE SUGGERE.
  #
  # Tant qu'un jeton est un fichier local, « pas de jeton » veut dire UNE chose : le
  # provisionnement n'a pas tourne, le conteneur est mal deploye, il ne doit pas demarrer — une
  # absence purement locale, definitive, qu'aucune attente ne repare.
  #
  # Ce jeton-ci se DEMANDE au service d'autorite, et la meme absence recouvre alors trois etats :
  #
  #   provisionnement manquant    LOCAL, DEFINITIF   -> le boot refuse, comme avant
  #   service d'autorite muet     LOCAL, TRANSITOIRE -> une unite qui n'a pas fini de demarrer
  #   forge injoignable           DISTANT, TRANSITOIRE
  #
  # Refuser le boot sur les deux derniers echangerait une panne rattrapable contre un conteneur mort —
  # et le message accuserait `provision-role-tokens.sh` pour un hoquet de reseau. C'est exactement
  # l'arbitrage ecrit dans l'etat cible : une panne partielle de forge est un comportement CORRECT,
  # le label reste, le poller reessaie, rien n'est perdu.
  #
  # ⚠ ET CE N'EST PAS « ON LAISSE PASSER » : les deux causes transitoires demarrent BRUYAMMENT. Un
  # boot vert sur un conteneur structurellement incapable de sceller est precisement le succes muet que
  # cette regle retire ailleurs ; on ne l'introduit pas ici.
  @signer_causes_fatales [:no_role_token, :no_forge_login, :bad_role, :not_a_worker]

  defp require_signer_tokens! do
    for role <- [
          Fleet.Project.Roles.gatekeeper_role(),
          Fleet.Project.Roles.conflict_resolver_role()
        ] do
      # Through `as_role/2` — the seal's own door — and not `Credentials.RoleToken` directly: the
      # boundary keeps RoleToken internal to Credentials, and probing through the exact call the
      # seal will make is the stronger proof anyway (same resolution, same policy).
      #
      # La CAUSE, elle, se redemande — et seulement sur le chemin d'echec. Le chemin heureux ne paie
      # rien, et la preuve reste celle de la porte que le sceau empruntera.
      if match?({:error, :role_token_unavailable}, Fleet.Forge.Client.as_role([], role)) do
        signer_verdict!(role, Fleet.Credentials.RoleIdentity.token_cause(role))
      end
    end

    :ok
  end

  defp signer_verdict!(role, {:ok, _token}) do
    # LA COURSE EST REELLE ET SON SENS EST LE BON : le jeton etait indisponible a l'appel precedent
    # et disponible a celui-ci. C'est un service qui vient de finir de demarrer. On demarre.
    Logger.warning(
      "pilot: le jeton du signataire #{inspect(role)} etait indisponible puis disponible entre " <>
        "deux appels — le service d'autorite finissait de demarrer. Boot poursuivi."
    )

    :ok
  end

  defp signer_verdict!(role, {:error, cause}) when cause in @signer_causes_fatales do
    raise "pilot: no role token for merge signer #{inspect(role)} (#{inspect(cause)}) — the seal " <>
            "signs merges fail-closed as this role and would refuse every merge on its path. " <>
            "Provision the token (runtime/services/provision-role-tokens.sh) before booting the rail."
  end

  defp signer_verdict!(role, {:error, cause}) do
    Logger.error(
      "pilot: le jeton du signataire #{inspect(role)} est INDISPONIBLE (#{inspect(cause)}) — ce " <>
        "n'est PAS un defaut de provisionnement, c'est une porte qui ne repond pas : le service " <>
        "d'autorite ou la forge. Le rail demarre parce que la cause est transitoire et que les " <>
        "merges reessaient, mais TOUT SCELLEMENT ECHOUERA tant qu'elle dure. " <>
        "« systemctl status lcars-catalogue », puis la joignabilite de la forge."
    )

    :ok
  end

  # Resolved forge base_url (app config `:forge`). `nil` if absent/empty. Source of the fail-loud guard
  # above (the multi-project step rail needs it to discover AND to derive the per-step-run remotes).
  defp forge_base_url do
    case Keyword.get(Application.get_env(:lcars_fleet, :pilot_forge, []), :base_url) do
      base when is_binary(base) and base != "" -> base
      _ -> nil
    end
  end
end
