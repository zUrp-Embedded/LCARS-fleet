# LCARS Runtime Audit — Final Campaign Report

**Date** : 2026-07-09
**Dernière révision** : 2026-07-10 (copie de référence — contenu non modifié sur le fond)
**Statut** : source externe — audit Codex SSOT/irrepr, référence read-only
**Référencé par** : `../PLAYBOOK.md`, `../LEDGER.csv`

Date: 2026-07-10
Target: `/home/lordzurp/audit/lcars/fleet/runtime/`
Status: coverage complete; remediation not started.

## Scope

Covered:

- every tracked Elixir source/test/config row under `fleet/runtime/`;
- runtime-local contract carriers tracked in `ledger-contracts.csv`: JSON/YAML canon and schemas, launch/gate scripts, runtime READMEs, close operational docs;
- runtime-local docs that describe current runtime truth.

Ignored by explicit campaign rule:

- `fleet/runtime/audit-report/`;
- top-level `docs/`, because it is months and many refactors behind the current runtime;
- external audit documents except when the user explicitly asked for architectural framing.

## Completion Proof

Command executed:

```text
/home/commons/codex/lcars-runtime-ssot-irrepro-2026-07-09/campaign/tools/coverage.sh
/home/commons/codex/lcars-runtime-ssot-irrepro-2026-07-09/campaign/tools/check-completion.sh
```

Output:

```text
# Coverage

Generated: 2026-07-10 17:43:11 CEST

## Primary Elixir Ledger

- total: 364
- not_read: 0
- reading: 0
- partial_finding: 0
- finding: 176
- read_clean: 188
- deferred: 0

## Secondary Contract Ledger

- total: 149
- not_read: 0
- reading: 0
- partial_finding: 0
- finding: 104
- read_clean: 45
- deferred: 0

## Rule

Coverage is not inferred from search results. A file is covered only when its ledger status changes according to `rules.md`.
Campaign completion gate passed.
```

## Source Of Truth

The exhaustive finding inventory is `findings-campaign.md`: 167 findings, `F-C001` through `F-C167`, each with severity/status/files/evidence/impact/repair direction.

The frontier map is `frontiers.md`. It groups local findings by architectural boundary without replacing the local evidence.

The clean inventory is `clean.md`; it records files read fully with no independent finding in this campaign.

The chronological audit journal is `worklog.md`; it records batch openings/closures, verification commands, and explicit non-inferences.

## Report Reading Order

For implementation work, read in this order:

1. `findings-campaign.md` for the exact defect and file/line evidence.
2. `frontiers.md` to see whether that defect belongs to a repeated boundary pattern.
3. `worklog.md` only when provenance or coverage sequence matters.
4. `clean.md` when checking why a neighboring file did not receive a finding.

Do not treat this file as a replacement for the finding inventory.

## Main Boundary Picture

B5 persisted/configured state is the dominant failure pattern. Many properties are still represented as raw strings/maps/config terms after the boundary where they should be parsed into closed domain values. This includes cap-profile fields, workflow-map fields, forge identifiers, audit/log config, launch defaults, role-token inventory, and runtime-local canon/docs.

B2 daemon-forge boundary has repeated identity and state-machine problems: repo/issue/branch identity is sometimes stringified before proof, forge write failures are sometimes flattened into successful or ordinary states, and several paths rely on convention rather than constructors.

B3 event mesh boundary is not an "add outbox" finding. The intended reliability model is: Bus is lossy fast path; forge + poll/reconciliation is the durable substrate. Findings in this boundary should be repaired by making the forge fact/backstop explicit, or by declaring the rail best-effort observability, not by adding a second durable event truth by default.

B4 module graph/topology has several hollow-green or stale-topology artefacts: gates that do not check what they claim, outdated graph comments, release/application-order drift, and duplicated protocol/catalogue surfaces.

B1 pod-daemon boundary remains cross-cutting: launch containment, credentials, pod identity, MCP/socket rails, and prompt composition all need to agree on the same closed facts.

## Final Batch Added

The last secondary batch added:

- F-C163 — checked-in run journal still presents stale runtime state as active resumable state.
- F-C164 — install.sh omits the vendor identity file required by publish-to-github's default path.
- F-C165 — role-token provisioning has a second hard-coded role list that diverges from canonical cap-profiles.
- F-C166 — bwrap isolation gate passes when the host secret being tested does not exist.
- F-C167 — gate-r0.8-canon exits green without running any canon checks.

## Remediation Framing

There are two layers of work:

- local repairs: exact files/tests/schemas/scripts named by each finding;
- architecture repair: reduce repeated B5/B2/B3/B4 patterns by moving facts into single constructors, generated inventories, and mechanically enforced boundary contracts.

Do not start with a broad refactor that erases local evidence. Fixes should either close a finding directly or introduce a boundary mechanism that makes a family of findings unrepresentable, with tests proving the old bad state cannot be constructed.

## Handoff

If a future agent resumes from here:

- do not re-open coverage unless the target scope changes;
- run `tools/check-completion.sh` first;
- read `campaign.md` and `plan.md` for the current checkpoint;
- use `findings-campaign.md` as the exhaustive work queue.
