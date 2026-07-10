# PLAN — le canard (garant : Claude, jamais délégué)

**Date** : 2026-07-10
**Dernière révision** : 2026-07-10
**Statut** : actif
**Référencé par** : `CARNET-DE-BORD.md`, `PLAYBOOK.md`

> Le plan maître. Il évolue (le canard est vivant), mais je reste seul garant : aucun worker ne l'édite.

## Objectif

167 findings Codex → **~15-20 constructeurs de frontière** + fermeture des hollow-gates + batch de la
dérive doc. Cible : sous « ouvre le source, casse au pif », plus de couture évidente. Chaque famille
rendue **inreprésentable** avec un test qui prouve que le vieux mauvais état ne se construit plus.

## Les 5 frontières (carte Codex, adoptée)

- **B1** pod↔daemon (containment, credentials, identité de rôle, MCP pod-facing, launch env)
- **B2** daemon↔forge (identité repo/issue/branch, écriture forge avalée→succès)
- **B3** event mesh (contrat `source×type×payload→consumers`, source-match, void/dormant)
- **B4** graphe de modules (topologie, hollow-green, docs stale) — **carte, pas archi**
- **B5** état persisté/configuré (**dominant** : donnée brute passée un boundary au lieu d'être parsée en valeur fermée)

## Phasage

| # | Phase | Contenu | Statut |
|---|---|---|---|
| 0 | **Verify-sweep** | Fan-out : trier les 167 (percé/théorique/déjà/doctrine) + citations | ⏳ EN COURS |
| 1 | **Hollow-gates** | Gates qui mentent (F-C167 vert-sans-check, F-C166 secret-absent, F-C013, F-C129) — nettoyer l'instrument de vérif AVANT de s'en servir | ⬜ |
| 2 | **B5 constructeurs** | ~poignée de smart-ctors d'entrée qui tuent la famille dominante | ⬜ |
| 3 | **B3 contrat events** | schéma payload + source-match + classification lifecycle + politique Cat-5 | ⬜ |
| 4 | **B2 échecs-avalés** | forge-write-fail→faux-succès (ma classe intégrité, exhaustive) | ⬜ |
| 5 | **Batch doc/narratif** | B4 dérive + mensonges (RoleToken, /etc, README, 37→38…) | ⬜ |

Checkpoint (relevé + user) entre chaque phase.

## Constructeurs de frontière pressentis (à confirmer par la vérif — hypothèse de regroupement B5)

> Hypothèse : les ~90 B5 se regroupent sous une poignée d'entrées. À VALIDER par le verify-sweep (ne pas
> présumer un constructeur avant d'avoir vu les findings percés qui l'exigent).

| Constructeur candidat | Entrée qu'il ferme | Findings pressentis (à confirmer) |
|---|---|---|
| `CapProfile` load/validate strict | chargement cap-profile → valeur fermée | F-C005, F-C053, F-C056, F-C141, F-C143… |
| workflow-map load strict | chargement workflow-map → data normalisée fermée | F-C109, F-C110, F-C159, F-C160… |
| Forge-id / GitRef constructor | repo/issue/branch → identité prouvée | F-C010/011, F-C054/055, F-C064/065, F-C085… |
| config/env parse-au-bord | clé config → valeur fermée, invalide=fail-loud | F-C032, F-C039, F-C082, F-C089, F-C097, F-C099, F-C104, F-C117… |
| event payload decode | payload event → struct fermée par type | F-C036, F-C092, F-C095, F-C101, F-C161… |
| Decision/verdict strict | gate-decision → schéma appliqué (reason requis) | F-C161, F-C096 |

Chaque ligne = **1 unité de travail** (design + test + fix des call-sites), pas N point-fixes.

## Journal des décisions (append-only)

- 2026-07-10 : montage. Worktree, ledger 167, playbook. Phasage arrêté. Rien fixé (règle cardinale).
