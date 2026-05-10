# PoC_unitaire — test unitaire interactif contre le corpus

**Date** : 2026-04-20
**Dernière révision** : 2026-04-20
**Statut** : actif — sprint PoC vers B1 round 1
**Référencé par** : `work/beyond/README.md`

## Principe

Miroir *partiel* de `work/moon-shot/` — on ne mirrore que les zones
normatives qui produisent des unités testables. Doctrine pure, vision,
glossaire ne sont pas mirrorés.

Une **unité** = un comportement normé dans le corpus dont l'échec
casse un cycle observable. Trop fin → rituel. Trop gros → intégration
déguisée. Règle de tranchage : unité = chose testable en ≤1 `test.sh`
runnable qui observe quelque chose.

Chaque nœud de l'arbre (feuille ET interne) peut avoir son propre
`test.sh`. Feuille = comportement unitaire. Interne = propriété
émergente de la composition des enfants. La hiérarchie porte la
compositionalité — pas de `PoC_integration/` orthogonal séparé.

## Layout par nœud

```
<unite>/
├── mandat.md           <- contrat corpus (extrait + pointeur)
├── test.sh             <- test executable, sortie [PASS]/[OBS]/[GAP]
├── impl-python/        <- implementation (optionnel, multiple possible)
├── impl-rust/
└── impl-elixir/
```

`mandat.md` dit ce qui doit être vrai. `test.sh` le vérifie. Les
impls sont interchangeables — elles passent toutes le même contrat,
ou pas.

## Règle de comptabilité (F1 vulcan 2026-04-20)

Quatre classes, ordre strict d'évaluation :

- **FAIL** — `test.sh` rc ≠ 0 OU sortie contient un `[FAIL]`. Régression.
- **PROVEN** — `test.sh` runnable + au moins un `[PASS]` observable + **zéro `[GAP]` résiduel dans la sortie**. Contrat testable effectivement établi.
- **PARTIAL** — au moins un `[PASS]` ET au moins un `[GAP]`. Une partie du contrat est prouvée, une partie reste à couvrir. Le `[GAP]` doit nommer précisément ce qui manque.
- **DRAFT** — aucun `[PASS]` encore (uniquement `[GAP]` ou silence). Mandat posé, probe pas encore écrit.

**Règle opposable** : PROVEN exige l'absence de `[GAP]`. Un test qui émet un mini-PASS + 3 GAP est PARTIAL, pas PROVEN. Sans cette discipline, la comptabilité est falsifiable : on ajoute une assertion verte triviale, on laisse les trous en `[GAP]`, et on remonte en PROVEN — ce n'est plus "contrat prouvé", c'est "au moins une primitive verte" (autre sémantique).

Pour un nœud interne (composition), la règle se propage : un nœud interne ne peut être PROVEN que si ses enfants sont PROVEN. Sinon il hérite PARTIAL ou DRAFT selon l'état des enfants.

Sortie canonique des `test.sh` :
- `[PASS] <assertion>` — comportement attendu confirmé
- `[OBS] <observation>` — fait noté, pas forcément attendu
- `[GAP] <trou>` — quelque chose n'est pas vérifiable ici, pointeur vers
  où ça doit être traité
- `[FAIL] <raison>` — comportement attendu violé
- `[WARN] <note>` — condition de configuration qui colore le résultat

## Ordre de construction

Par densité normative descendante, pas par ordre de lecture corpus :

1. `10-beyond/contrat-runtime-minimal/` ← en cours
2. `10-beyond/objets-runtime/`
3. `10-beyond/spawn-pod/`
4. `04-phase-1-core/fleet-pilot/`
5. `04-phase-1-core/ipc-native-structuredio/`
6. `04-phase-1-core/workers-critiques/` (absorbera PoC-01)
7. `10-beyond/provisioning/`
8. ... ADRs, doctrines restantes si unités.

Les 5 Tier 1 + B1a/B1b déjà faits migrent comme feuilles dans les
nœuds appropriés au fil.

## État global et autorité (F2 vulcan 2026-04-20)

**Source d'autorité d'état** : le `test.sh` de chaque unité quand il est lancé. Ce qu'il émet en sortie est l'état courant. Le `mandat.md` porte le contrat ; il doit être synchrone avec la sortie test.sh (si mandat dit "PROVEN" mais test.sh émet des `[GAP]` = drift documentaire, à corriger).

**Index généré** : `index.md` est produit par `bash run-all.sh > index.md` ou équivalent. Ce n'est pas un document maintenu à la main. S'il diverge de la sortie `run-all.sh` → regénérer, pas patcher.

Commande canonique :
```
bash run-all.sh
```

Sortie par classe (PROVEN / PARTIAL / DRAFT / FAIL). Le FS reste la base — pas d'état caché ailleurs.
