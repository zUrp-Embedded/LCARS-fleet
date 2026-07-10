# CONSOLIDATION phase 0 — verify-sweep des 167

**Date** : 2026-07-10
**Dernière révision** : 2026-07-10
**Statut** : phase 0 CLOSE — 167/167 vérifiés · checkpoint user
**Référencé par** : `PLAN.md`, `CARNET-DE-BORD.md`

## Distribution (167, verdicts vérifiés contre le code réel + citations)

| Verdict | N | % | Sens |
|---|---|---|---|
| **DOCTRINE** | **71** | 42,5 % | décision de design → **te revient** (groupées en 7 clusters ↓) |
| **PERCE** (code) | 49 | 29,3 % | brèche réelle+atteignable → verrou (6 familles ↓) |
| **PERCE-doc** | 25 | 15,0 % | correction mécanique doc/commentaire/log/test |
| **THEORIQUE** | 21 | 12,6 % | **PAS de fix** — verrou amont existe déjà / dormant / aucun chemin réel |
| **DEJA-FIXE** | 1 | 0,6 % | F-C130 (dep app réelle neutralise déjà) |

**Gain de la règle cardinale** : 21 findings (dont plusieurs high/medium chez Codex) **dissous à la vérif** — le schéma JSON verrouille déjà à l'entrée (F-C005/015/032/039/096), le producteur passe toujours des valeurs valides (F-C054/057/065/077/078), ou la prose n'est jamais assemblée dans un pod (F-C149/150/154/155). **On n'aurait fixé 21 non-brèches.** + plusieurs localisations corrigées (le vrai verrou est un niveau au-dessus de la ligne pointée : F-C037→task_probe.ex:72, F-C119→admission).

## PERCE code (49) — 6 familles de verrous

| Fam | Verrou | Findings | Phase |
|---|---|---|---|
| **F — hollow-gates & scripts** | rendre le gate réel / compléter script | 160, 164, 165, 166, 167 | **1** |
| **C — parse-au-bord INGRESS/data** | smart-ctor à l'entrée HTTP/webhook/event/champ-schéma-ouvert | 010, 018, 029, 031, 069, 086, 092, 098, 100, 119 | **2** |
| **B — parse-au-bord CONFIG** | lecteur config → valeur fermée, fail-loud sur malformé | 082, 097, 099, 104, 107, 117 | **2** |
| **D — identité / collision** | constructeur d'identité (forge-id, pod-id, slug, base_sha, hash) | 022, 027, 028, 055 | **2** |
| **E — schéma/contrat imposé** | champ requis au schéma OU contrat appliqué au runtime | 141, 161 | **2/3** |
| **A — fail-closed sur échec avalé** | surface l'échec / typed-return au point cité (classe intégrité, exhaustive) | 035, 037, 043, 044, 047, 053, 059, 060, 062, 066, 068, 073, 074, 075, 076, 079, 084, 106, 113, 114, 115, 116 | **4** |

→ **Le travail « constructeur » (B/C/D/E, ~22 findings) s'effondre en ~5-6 smart-ctors** (config-parse, forge-id/GitRef, event-payload decode, pod-id/slug, cap-name pattern, gate-decision strict). **La famille A (~22)** = ~22 edits fail-closed ciblés, petits, sur le pattern déjà prouvé cette session (mes 9 B-#). **Gates (F, 5)** = 5 fixes. **Doc (25)** = 1 batch mécanique. → **Total code : ~6 constructeurs + ~22 fail-closed + 5 gates + 25 doc-fix.** Tractable, énumérable.

## DOCTRINE (71) — 7 clusters de décision (POUR TOI)

> Aucune ne se fixe seule. Je propose, tu tranches. Groupées pour que ce soit ~7 décisions, pas 71 questions.

| # | Cluster | Question à trancher | Findings (~) |
|---|---|---|---|
| **D1** | **Fiabilité events/escalades** — best-effort vs load-bearing | Pour chaque rail (Cat-5, coord, audit, boot, incident), fail-closed ou observabilité-best-effort-assumée ? (plusieurs déjà surfacés `:degraded` par Readiness — reste le fail-loud au chemin d'appel) | 019,046,051,058,089,091,093,095,101,102,103,105 |
| **D2** | **Stubs MVP / dormant documenté** | Câbler / marquer inactif / renvoyer 501 : read-models observation/api, GIT_MIRROR, gatekeeper content-agnostic, NoOpDispatcher | 038,042,105,118,120,124,125,126,135,136 |
| **D3** | **Canon Memory-X / legacy / modop-bundles** | Le grand ménage canon : relocate/archiver/câbler le dormant (frozen-monks, non-v2.5, modop non-assemblés, subagent-templates) | 133,138,139,140,144,145,146,147,152,153,156,157,159 |
| **D4** | **Config operateur : require-au-boot vs soft-default** | Quelles clés `Application.get_env` doivent fail-loud au boot au lieu d'un défaut mou | 034,036,040,041,049,052,056,063,064 |
| **D5** | **Tolérances délibérées vs fail-closed** | Revisiter chaque dégradation documentée (garder ou resserrer) | 001,016,021,033,045,048,050,080,081,083 |
| **D6** | **Complétude policy / SSOT cross-surface** | forge-blind roles, catalogue cross-langage (Python↔Elixir), id-vs-number, severity-knobs, gatekeeper lifecycle | 007,011,013,108,109,110,111,112,142,143 |
| **D7** | **Outillage** | Credo checks off, Sobelow hors-gate, Dialyzer scope, exclusions test périmées | 023,026,121,122,123,127,129 |

## THEORIQUE (21) — WONTFIX documenté (le verrou amont existe déjà)

005,015,020,024,025,030,032,039,054,057,065,077,078,085,094,096,149,150,154,155,163. → chacun a la preuve du non-fix dans son lot (`verdicts/`). À reconfirmer avant toute action ; ne PAS fixer.

## Plan raffiné

- **Phase 1** — F (gates/scripts) : 160,164,165,166,167. Petit, haute valeur (nettoyer l'instrument de vérif).
- **Phase 2** — B/C/D/E (constructeurs) : ~5-6 smart-ctors qui tuent ~22 findings.
- **Phase 3** — E/D1 (contrat events) : gate-decision strict + payload canonique + les décisions D1 tranchées.
- **Phase 4** — A (fail-closed) : ~22 edits ciblés.
- **Phase 5** — doc-batch (25 PERCE-doc) + retrait crons.
- **En parallèle** : **triage DOCTRINE** (D1-D7) avec le user — nécessaire avant phases 3 et une partie de 4.
