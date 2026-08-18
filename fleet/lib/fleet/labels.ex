defmodule Fleet.Labels do
  use Boundary, deps: [], exports: []

  @moduledoc """
  Label vocabulary of the forge-state-machine **wire-protocol**: the forge IS the state machine,
  these labels are its thread. SINGLE SOURCE.

  A foundation boundary (`deps: []`) because BOTH `Fleet.Pilot` (poller/dispatcher/completer/consumer)
  AND `Fleet.MCP` (the arch's delegation reads `stage/merged` / `lcars-awaits-arch`) must name these
  labels byte-for-byte — and MCP cannot depend upward on Pilot: the shared vocabulary lives BELOW both.

  These constants ARE NOT config: they ARE the protocol. Re-declaring one as a local `@attr` or
  literal = silent drift on a rename. Centralized here, consumed everywhere.

  Compile-time usage (preserves the constant semantics, usable in `cond`/pattern):

      @in_flight_label Fleet.Labels.in_flight()

  or runtime direct (`Fleet.Labels.awaits_arch()`).

  FOUR families, and the split that matters is scoped-vs-flat. The MUTEX is Gitea's — a label
  carrying `exclusive: true` removes the others of its scope when set — but the RULE that a `/` in
  the name means exclusive is OURS: `ForgeClient` derives the field from the name at creation
  (`exclusive: String.contains?(name, "/")`). Gitea reads the FIELD, never the name.

  The distinction is not pedantic. Written as "because Gitea reads it", the convention looks like a
  server behaviour one can rely on anywhere; it is a house heuristic applied by ONE call site, so a
  label created by any other route — a human, a script, a forge that is not Gitea — carries no
  mutex at all, and nothing reconciles it afterwards (`EditLabelOption` exposes the field; we never
  re-read it).

    * FLAT LOCKS `lcars-in-flight` / `lcars-awaits-arch` — concurrency / escalation.
    * SCOPED POSITION `wfmap/<map>` + `stage/<step>` — the workflow_map position; the state lives
      in the label and the mutex is native.
    * SCOPED DESTINATION `destination/workshop` — an INPUT to the burn (which card gets engraved).
    * FLAT VISUAL `type:*` — decoration, `:` and not `/` so the namespace cannot be mistaken for a
      routing scope. Nothing mechanical reads it back.

  The first three MEAN something to the machine; the fourth means something only to a human. That
  asymmetry is a trap, not a detail: a wrong routing label breaks something and gets found, a wrong
  visual label breaks nothing and simply misinforms every reader (measured 2026-08-03 — a doc
  ticket wearing `type:feature`). Hence `type_for_destination/1`: the decoration is DERIVED from the
  routing decision, never posted as its own constant.

  This list said "two families" until 2026-08-03, and closed with "outside these two families, a
  label does not exist" — while `genre/doc` (as it was then called) had been shipping for a chantier and `type:feature` was
  posted on every issue ever created. Keep it counted right: the sentence that bounds a vocabulary
  is the first thing a reader trusts and the last thing anyone updates.
  """

  @in_flight "lcars-in-flight"
  @awaits_arch "lcars-awaits-arch"
  # ONE LITERAL FOR THE FACE, and the label is derived from it. Three places used to spell it
  # independently — the wire enum offered to the arch, the clause that routes the wire value, and
  # the label posted on the forge — so the wire could ANNOUNCE a token the code did not accept and
  # nothing would be red (measured: renaming the enum alone survived the whole suite). It shipped
  # exactly that way: the wire said `"ops"` long after the deliverable moved to `workshop`.
  @destination_workshop_token "workshop"
  @destination_workshop "destination/" <> @destination_workshop_token

  @doc "\"Pod in flight\" lock: set BEFORE the spawn (anti double-spawn), lifted at end-of-step-run."
  @spec in_flight() :: String.t()
  def in_flight, do: @in_flight

  @doc "HUMAN lock: the issue awaits an action via the arch (escalate/halt/redirect verdict)."
  @spec awaits_arch() :: String.t()
  def awaits_arch, do: @awaits_arch

  @doc """
  DESTINATION marker of a WORKSHOP ticket (`destination/workshop`): an INPUT to the
  workflow-map burn — present on a routeless issue, the poller engraves the doc card instead of
  the project's declared card; absent, nothing changes. Read ONCE at burn time: the engraved
  `wfmap/*` stays the only route (the forge is the state machine). Distinct namespace from
  `type:*` on purpose — those are documented visual-never-routing, and this one routes.
  """
  @spec destination_workshop() :: String.t()
  def destination_workshop, do: @destination_workshop

  @doc """
  The WIRE token of the workshop destination (`"workshop"`) — what an architect passes to `issue_create`,
  and the value the routing clause matches. Same literal as `destination_workshop/0`'s scope, on purpose: the
  token names the FACE the deliverable lands on, and a wire that offers a token the handler does
  not accept refuses every documentary ticket while looking perfectly documented.
  """
  @spec destination_workshop_token() :: String.t()
  def destination_workshop_token, do: @destination_workshop_token

  @doc """
  VISUAL type of a ticket, derived from its destination — `type:workshop` for a ticket whose
  deliverable stays in the workshop (wire token `"workshop"`, label `destination/workshop`),
  `type:feature` otherwise. Flat and NON-routing by construction: `:` and not `/`,
  so Gitea creates it non-exclusive and no code reads it back. It exists for the human who scans
  a list of issues and wants to know what kind of thing each one is.

  DERIVED, never posted as a constant: the destination is resolved at create time, and a visual type
  contradicting it is a lie told by the interface — a doc ticket wearing `type:feature` (measured
  2026-08-03) says "feature" to every human who reads the list, while the burn routes it to the
  doc card. One decision, one source; the label follows.
  """
  @spec type_for_destination(String.t() | nil) :: String.t()
  def type_for_destination(@destination_workshop_token), do: "type:workshop"
  def type_for_destination(_), do: "type:feature"

  @doc "The visual types, for the seeding that must create them before anyone can wear them."
  @spec visual_types() :: [String.t()]
  def visual_types, do: ["type:feature", "type:doc"]

  # --- workflow_map position: 2 mutex label scopes (via `exclusive:true`, set PER-REPO by
  # ForgeClient.ensure_repo_label). `wfmap/<map>` = WHICH map (data, per-issue → multi-map);
  # `stage/<step>` = the CURRENT step, mobile. brief-review/build values come from the MAP (data);
  # review/merged = phases of the PR LIFECYCLE (post-map mechanism, human-only: the machine does not re-read
  # get_route on an issue in review [PR-backed → skip] nor merged [closed]).
  @stage_prefix "stage/"
  @wfmap_prefix "wfmap/"
  @stage_review "review"
  @stage_merged "merged"
  # Fermeture SANS livraison (supersede, abandon) — le pendant positif de `merged`. Cf. `stage_retired/0` :
  # sans lui, « pas livré » ne s'exprimait que par l'ABSENCE de `merged`, et une absence n'est pas un fait.
  @stage_retired "retired"

  @doc "Scoped prefix of the current step (`stage/`). Scoped → exclusive (mutex)."
  @spec stage_prefix() :: String.t()
  def stage_prefix, do: @stage_prefix

  @doc "Scoped prefix of the tracked map (`wfmap/`)."
  @spec wfmap_prefix() :: String.t()
  def wfmap_prefix, do: @wfmap_prefix

  @doc "PR LIFECYCLE step: the issue enters review (deliverable PR opened). Mechanism, not a map step."
  @spec stage_review() :: String.t()
  def stage_review, do: @stage_review

  @doc "PR LIFECYCLE step: the brick is merged (terminal). Mechanism, not a map step."
  @spec stage_merged() :: String.t()
  def stage_merged, do: @stage_merged

  @doc """
  Stage of a ticket closed WITHOUT delivering — its work moved elsewhere (supersede) or was
  dropped.

  It exists because the opposite fact was EMERGENT. Nothing in the tree said "a closed ticket is a
  delivered ticket": it held only because no actor owns a close gesture (the human's team is
  `read`, the architect has no close tool, and the four closing paths are all runtime). An
  invariant that rests on the absence of a tool is one `add a close button` away from lying — and
  everything downstream reads the closure, not the intent behind it: a dependency releases on a
  CLOSED blocker whatever killed it.

  So the closure states its own nature, and this label is the half that says "not delivered". Its
  twin is `stage/merged`. Being in the SCOPED `stage/` family is what makes them mutually
  exclusive: a ticket cannot carry both, and the forge itself enforces it.
  """
  @spec stage_retired() :: String.t()
  def stage_retired, do: @stage_retired

  # ============================================================
  # FIFTH FAMILY — SCOPED WAIT (BL-6-48, step 1 of its plan)
  # ============================================================
  # `wait/<reason>` — what a ticket is WAITING FOR, when it is alive with no active pod.
  #
  # SCOPED on purpose, and it buys the hard half for free: `ForgeClient.ensure_repo_label` creates a
  # name containing `/` as `exclusive: true`, so setting `wait/capacity` REMOVES `wait/role` with no
  # code guarding it. Two simultaneous waits are unrepresentable natively, exactly like `stage/`.
  #
  # ⚠ What exclusivity does NOT buy: LEAVING the wait. It acts when another label of the scope is
  # SET; a ticket that stops waiting sets nothing. That removal is the caller's job, and it is the
  # point where this family could manufacture the very "stale state" the entry exists to kill.
  @wait_prefix "wait/"

  @doc "Scoped prefix of the wait reason (`wait/`). Scoped → exclusive (native mutex)."
  @spec wait_prefix() :: String.t()
  def wait_prefix, do: @wait_prefix

  @doc """
  Maps a dispatch skip reason to its `wait/*` label, or `nil` when the reason must stay SILENT.

  This function IS the deliverable of BL-6-48 — not the wiring. Five labels for seventeen measured
  reasons, and the twelve `nil` each carry a reason of their own: without them a reader finds twelve
  apparent oversights and adds twelve labels. **A `nil` by decision and a `nil` by omission read the
  same in code** — only the exhaustiveness test tells them apart, so it is not optional.

  Raises on an UNKNOWN reason, deliberately. A silent fallthrough is how the eighteenth reason would
  be born mute — which is literally what happened while measuring for this table: six tuple-shaped
  reasons were invisible to a grep that could only match atoms, one of them added an hour earlier by
  the same hand. An instrument that cannot see a shape accuses the material of not having it.
  """
  @spec wait_for(term()) :: String.t() | nil
  # ─── The five that earn a label: a real wait, invisible today ──────────────────────────────────
  # A queued ticket is indistinguishable from a forgotten one — that ambiguity already cost a false
  # diagnosis (cf. the entry).
  def wait_for(:at_capacity), do: @wait_prefix <> "capacity"
  # Same label as the global cap, deliberately: the ticket waits for a seat, and WHICH ceiling
  # holds it is an operator's diagnosis, not a distinct state of the ticket. Two labels here would
  # make a human learn a taxonomy to read "not started yet".
  def wait_for(:role_at_capacity), do: @wait_prefix <> "capacity"
  def wait_for(:role_busy), do: @wait_prefix <> "role"

  # A0.5 — a conflict-rework dispatch whose live pod could not get its `refs/lcars/base` refreshed
  # (the base moved; briefing on the stale one would replay the measured failure, one budget round
  # per tick). Same label as `:role_busy`, deliberately: from the ticket's seat both read "the
  # producer is not ready for me yet, retry next tick" — WHICH readiness is missing is an
  # operator's diagnosis (the refresh failure is already logged loud pod-side), not a distinct
  # state of the ticket.
  def wait_for(:stale_base_unrefreshed), do: @wait_prefix <> "role"
  def wait_for(:draining), do: @wait_prefix <> "draining"
  def wait_for(:criterion_unavailable), do: @wait_prefix <> "criterion"
  def wait_for(:ci_pending), do: @wait_prefix <> "ci"
  # Précondition NON satisfaite : un bloqueur déclaré sur la forge est encore ouvert. Le ticket
  # n'attend ni la fleet ni un juge — il attend un AUTRE ticket, et c'est ce que l'étiquette dit.
  def wait_for({:depends, _blocker}), do: @wait_prefix <> "depends"

  # La porte des dépendances n'a pas pu LIRE les arêtes. Même étiquette que ci-dessus, et pour la
  # même raison que la porte CI : du côté du ticket c'est le même fait — il est arrêté à cette porte
  # et personne ne travaille dessus. La distinction vit dans la raison du skip, où elle est
  # actionnable ; l'étiquette répond « que fait ce ticket », pas « quel appel a échoué ».
  def wait_for({:depends_unreadable, _why}), do: @wait_prefix <> "depends"
  # The CI door defers on a read it could not make (PR object, status list, or the marker that
  # bounds the red loop). From the ticket's side these are ALL the same fact — it is stopped at the
  # CI gate, and nobody is working on it — so they share `wait/ci` rather than teaching a human
  # three names for one wait. The distinction lives in the skip reason (logs, tally), where it is
  # actionable; the label answers "what is this ticket doing", not "which call failed".
  def wait_for({:ci_head_unreadable, _why}), do: @wait_prefix <> "ci"
  def wait_for({:ci_unreadable, _why}), do: @wait_prefix <> "ci"
  def wait_for({:ci_red_marker_unreadable, _why}), do: @wait_prefix <> "ci"

  # La porte CI attend sur une echeance qu'elle ne peut pas atteindre (date de PR illisible → l'age
  # vaut 0, donc le delai n'est jamais franchi). Meme etiquette que ses voisins, meme raison : du
  # cote du ticket c'est le meme fait — arrete a la porte CI. La distinction vit dans la raison du
  # skip, ou un operateur peut agir dessus.
  def wait_for({:ci_deadline_unreachable, _why}), do: @wait_prefix <> "ci"

  # ─── Already carried by an existing label: a second one would be a second truth ────────────────
  # The one you read is never the one somebody corrected.
  def wait_for(:in_flight), do: nil
  def wait_for(:awaits_arch), do: nil
  # Its open PR IS the state, and it is what a human looks at. The ticket is not waiting on the
  # fleet — the fleet is working on it, one rail over.
  def wait_for(:pr_open), do: nil

  # ─── Not a wait: a config failure, and it has its own rail (BL-6-47.2 wired the incident) ──────
  def wait_for(:no_role), do: nil

  # ─── Not OUR ticket: a foreign PR has nothing to receive from us ───────────────────────────────
  def wait_for(:not_fleet_branch), do: nil

  # ─── Transitions and terminals: nothing is waiting ─────────────────────────────────────────────
  # `onboarded` just entered and leaves on the next tick; `merged`/`cancelled` never come back.
  def wait_for(:onboarded), do: nil
  def wait_for(:merged), do: nil
  def wait_for({:cancelled, _pr}), do: nil

  # ─── Escalations already RESOLVED: `lcars-awaits-arch` is posted by those very paths ───────────
  def wait_for({:rework_exhausted_escalated, _pr}), do: nil
  def wait_for({:merge_blocked_escalated, _pr}), do: nil
  def wait_for({:publish_brake_escalated, _pr}), do: nil

  # ─── The red is already GRAVED, and the producer is already reworking on it ────────────────────
  # `[ci-red:pr-N:<sha>]` on the PR carries the failure and its sha, and the rework it triggered is
  # in flight. A `wait/ci` label here would say "waiting on the CI" about a ticket whose CI has
  # already ruled — the opposite of what happened.
  def wait_for({:ci_red_already_signalled, _sha}), do: nil

  # ─── Provenance wall: its forge trace exists since `d31ed188a` (BL-6-47.4) ─────────────────────
  def wait_for({:head_read_failed, _why}), do: nil

  # ─── `draft` — TWO shapes for one concept, and the unification is NOT this function's call ─────
  # A human putting a PR in draft makes a DECISION; the fleet undergoes it. Saying "the fleet waits"
  # is mechanically true and socially false — it inverts who is waiting on whom. Pending the user
  # arbitration, both shapes stay SILENT rather than guess.
  def wait_for(:draft), do: nil
  def wait_for({:draft, _pr}), do: nil

  # ─── The wall (BL-6-48): an unknown reason FAILS instead of being born mute ────────────────────
  def wait_for(reason) do
    raise ArgumentError,
          "Fleet.Labels.wait_for/1: reason #{inspect(reason)} is absent from the BL-6-48 table. " <>
            "Add it with a label OR with an explicit nil AND its argument — a silent fallthrough " <>
            "is how a reason is born mute."
  end
end
