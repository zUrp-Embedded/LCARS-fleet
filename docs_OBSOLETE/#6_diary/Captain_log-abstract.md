**Date** : 2026-03-09
**Dernière révision** : 2026-03-30
**Statut** : standalone abstract — synchronisé manuellement avec Captain_log.md
**Référencé par** : Captain_log.md

# LCARS Fleet — Abstract

*Un mois. 28 phases. Une contrainte hardware qui invente une architecture, puis un système qui finit par se fabriquer lui-même.*

---

## Genèse — la contrainte qui impose la structure

Tout commence par un projet concret : cDs, un serveur astronomique embarqué ARM64. La compilation cross depuis x86 force une première division : coder d'un côté, compiler de l'autre. Trois instances WSL2, un protocole IPC naissant : des fichiers markdown dans `/home/commons/handoff/`. Pas d'API, pas de broker — juste `dev-to-build.md` qu'un agent lit au démarrage et met à jour en fin de session. Simple, versionnifiable, inspecté à l'œil.

L'architecture n'a pas été conçue. Elle a été contrainte.

---

## Phases 1–10 — du projet au système (2026-03-01 → 03-07)

| Phase | Date | Pivot |
|---|---|---|
| 1 — Genèse | 03-01 | cDs/ARM64 force dev/build, IPC fichier émerge |
| 2 — Généralisation | 03-02 | Suppression préfixe `cDs-`, fleet orchestrator TUI, dual-engineer |
| 3 — Tokens | 03-03 matin | Optimisation budget : scripts shell vs Edit tool, gain 6–12× |
| 4 — Audit IPC + qualifier | 03-03 après-midi | Formalisation protocole, ajout instance qualifier |
| 5 — Consolidation | 03-03 soir | Hardening, backlog, merge des repos → source de vérité unique |
| 6 — Premier qualifier auto | 03-04 nuit | Tests automatisés, premier CI gate |
| 7 — Migration ext4 | 03-04 après-midi | Builds sur ext4, homes sur drvfs/NTFS — règle immuable |
| 8 — Comportement émergent | 03-05 nuit | engineer intercepte un ACK qualifier destiné à architect, fixe et déploie seul |
| 9 — PoC multi-user WSL2 | 03-05 après-midi | Le modèle mono-distro multi-user est validé comme base du futur runtime |
| 10 — Cristallisation | 03-07 | LCARS cesse d'être un assemblage de scripts ; le système se nomme enfin lui-même |

Les trois invariants qui n'ont jamais changé depuis la Phase 1 :
1. Les fichiers markdown comme IPC
2. La source de vérité unique (un fichier versionné, jamais la mémoire volatile)
3. L'orchestrateur observe, ne commande pas — les workers restent autonomes

---

## Phases 11–18 — le système se déploie sur lui-même (2026-03-08 → 03-15)

Phase 11 pose l'inférence : pas de magie au niveau token, mais une architecture qui réduit la dérive par répétition systématique des règles. Phase 12 formalise les Starfleet Principles. Phase 13 est la première vraie install. Phase 14 valide que le système peut déjà se corriger lui-même dans les limites de son cadre.

À ce stade, LCARS n'est plus seulement un dispositif pour piloter des agents. Il devient le projet que sa propre infrastructure commence à produire, auditer et corriger.

---

## Phases 19–28 — qualification, externalisation, regard externe (2026-03-22 → 03-28)

À partir de la Phase 19, le projet change encore de nature. Il ne s'agit plus seulement de construire LCARS, mais de le qualifier :

- hardening du runtime
- premières vraies installs
- plans de qualification
- lecture IEC 61508
- mise en forme du projet comme système gouverné
- puis regard externe à froid par un autre modèle

Le point crucial est que LCARS devient alors **le premier produit de sa propre infrastructure**. Le repo, les corrections, la doc, les audits, les plans de qualification et une partie de sa propre théorie ont été produits dans la boîte qu'il décrit.

---

## Ce que le système dit de lui-même

**Prompt engineer** : opère au niveau token, reformule indéfiniment. Résultats bons en démo, fragiles en production.

**Directive engineer** : encode des règles dans `CLAUDE.md`. Mieux — mais opère encore au niveau comportemental.

**Directive-master** : conçoit une architecture de gouvernance. Les directives ne décrivent pas des comportements — elles définissent des rôles, des scopes, des escalades, des canaux IPC, des protocoles d'erreur. L'agent n'est pas instruit, il est *instancié*.

Un agent instruit peut dériver. Un agent instancié opère dans un périmètre dont il ne sort pas sans signal explicite.

**Nuance honnête** : LCARS ne rend pas la dérive impossible. Il la rend statistiquement improbable par architecture. Pas de magie au niveau tokens. La supériorité est architecturale, pas ontologique.

**Nuance plus tardive** : le projet ne promet pas un agent déterministe. Il cherche un système global à comportement plus borné malgré des composants probabilistes.

---

*→ Récit complet : Captain_log.md (~1300 lignes)*
