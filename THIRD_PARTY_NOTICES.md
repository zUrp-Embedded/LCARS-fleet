# Third-Party Notices

**Date** : 2026-08-04
**Dernière révision** : 2026-08-09
**Statut** : actif — recensement des emprunts externes (Apache-2.0 §4)
**Référencé par** : `runtime/vendor/*/VENDOR.md`

LCARS-fleet est distribué sous **AGPL-3.0** (voir [`LICENSE`](LICENSE)). Ce document recense les travaux tiers dont le projet dérive, sous quelque forme que ce soit — code copié, code réimplémenté, ou méthode reprise.

Il couvre volontairement plus que ce que les licences exigent. Une réimplémentation propre n'oblige à rien juridiquement ; nous la déclarons quand même, parce qu'une dette intellectuelle non dite reste une dette.

Si vous estimez qu'un travail vous appartenant figure ici de manière incorrecte, ou qu'il devrait y figurer et n'y est pas, ouvrez un ticket : nous corrigerons.

---

## Comment lire ce document

Chaque emprunt est qualifié par sa **forme**, parce que les obligations et les risques n'ont rien à voir d'une forme à l'autre :

| Forme | Ce que ça veut dire | Obligations |
|---|---|---|
| **`import`** | fichiers copiés tels quels dans notre arbre | licence + copyright conservés, modifications signalées |
| **`recode`** | réimplémenté à partir de la lecture du code source d'origine | aucune au sens strict — attribution par honnêteté |
| **`pattern`** | méthode ou doctrine reprise, prose entièrement réécrite | aucune — attribution par honnêteté |
| **`dep`** | dépendance externe chargée à l'exécution, non redistribuée | aucune — mention pour la traçabilité |

---

## Récapitulatif

| Projet | Auteur | Licence | Forme | Emplacement |
|---|---|---|---|---|
| [token-saver](https://github.com/ppgranger/token-saver) | ppgranger | Apache-2.0 | `import` | `runtime/vendor/token_saver/` |
| [wshobson/agents](https://github.com/wshobson/agents) | wshobson et contributeurs | MIT | `import` | `knowledge/wshobson-agents/` |
| [GitWand](https://github.com/devlint/GitWand) | devlint | MIT | `recode` | `runtime/lib/fleet/conflict.ex` |
| [superpowers](https://github.com/obra/superpowers) | Jesse Vincent | MIT | `pattern` + `dep` — **RETIRÉ le 2026-08-19** | *(plus aucun fichier ; cf. §4)* |

---

## 1. token-saver — `import`

- **Source** : https://github.com/ppgranger/token-saver
- **Auteur** : ppgranger
- **Licence** : Apache License 2.0 — texte intégral conservé en [`runtime/vendor/token_saver/LICENSE.upstream`](runtime/vendor/token_saver/LICENSE.upstream)
- **Version reprise** : commit `098873e04c6c49cbdc25c1c5f795986f5f170f16` (2026-06-02), soit
  `v1.3.1-84-g098873e` — **le commit fait foi, pas une étiquette de version**. Cette ligne a annoncé
  « v2.6.3 » : faux, ce tag est 16 commits plus loin (`0767a57`, même date). Vérifiable :
  `runtime/vendor/token_saver/update_vendor.sh --verify` compare le sous-arbre au commit déclaré.

**Ce qui est repris** : les répertoires `src/`, `scripts/` et `tests/` — 67 fichiers Python, moteur de compression d'output CLI et ses 36 processeurs spécialisés.

**Ce qui ne l'est pas** : `installers/`, `.claude-plugin/`, `antigravity/`, `bin/`, `docs/`.

**Modifications apportées au code repris : aucune.** Le sous-arbre est une copie strictement identique à l'amont. Les correctifs et l'adaptation LCARS vivent dans des fichiers séparés (`adapter.py`, `lcars_*.py`), hors du sous-arbre. Ce choix sert autant la conformité — Apache-2.0 §4(b) impose de signaler les fichiers modifiés, il n'y en a aucun — que la maintenance : la mise à jour amont est une re-copie, sans patch à rejouer.

**Détail complet** : [`runtime/vendor/token_saver/VENDOR.md`](runtime/vendor/token_saver/VENDOR.md) — provenance, découpage, correctifs, procédure de suivi amont.

---

## 2. wshobson/agents — `import`

- **Source** : https://github.com/wshobson/agents
- **Auteur** : wshobson et contributeurs
- **Licence** : MIT
- **Emplacement** : `knowledge/wshobson-agents/` (22 fichiers)

**Ce qui est repris** : 10 des 74 bibliothèques d'agents publiées par le projet, versées dans la base de connaissance L2 de la fleet.

L'attribution et la notice de copyright figurent dans [`knowledge/wshobson-agents/README.md`](knowledge/wshobson-agents/README.md), conformément à la licence MIT.

---

## 3. GitWand — `recode`

- **Source** : https://github.com/devlint/GitWand
- **Auteur** : devlint
- **Licence** : MIT
- **Version étudiée** : v3.6.0, commit `31c25baa1`
- **Emplacement** : `runtime/lib/fleet/conflict.ex` (135 lignes, Elixir)

**Aucune ligne de code n'a été copiée.** Le moteur d'origine est en TypeScript ; LCARS tourne sur la BEAM. Le cœur déterministe de résolution de conflits (analyse, huit motifs triviaux, diff LCS, score, trace de décision, assemblage) a été **réimplémenté en Elixir** à partir de la lecture du code source.

La périphérie du projet d'origine — résolveurs sensibles au format, fusion structurelle par AST, repli LLM, interface MCP, application de bureau — a été délibérément écartée après audit.

Le module porte la mention de sa filiation dans son `@moduledoc`. Le travail dérive d'une lecture attentive d'un travail publié : nous le déclarons, même si la MIT n'impose rien pour une réimplémentation.

**L'étude elle-même vit HORS de ce dépôt, et y reste délibérément** : c'est du reverse-engineering du produit de quelqu'un d'autre, reproductible par qui refait le même travail. On crédite l'origine ; on ne publie pas quatre mois d'exploration du code d'un tiers. Aucun texte de licence n'est reproduit ici puisque aucune ligne de GitWand n'est présente — cette entrée est une attribution d'**ORIGINE**, pas une obligation de licence qu'on acquitte, et c'est écrit parce que la distinction cesse d'être évidente dès que la prose qui la portait a bougé.

La chaîne complète — audit, ce qui a été gardé, ce qui a été refusé et pourquoi — est dans le `@moduledoc` de `Fleet.Conflict` (`runtime/lib/fleet/conflict.ex`) et dans l'historique git du portage.

---

## 4. superpowers — `pattern` et `dep` — **RETIRÉ**

- **Source** : https://github.com/obra/superpowers
- **Auteur** : Jesse Vincent
- **Licence** : MIT
- **Statut** : **plus aucun fichier de ce dépôt ne dérive de ce corpus** (retrait du 2026-08-19)

**Cette section reste au passé plutôt que d'être supprimée.** Un emprunt a eu lieu ; l'effacer
réécrirait l'histoire du dépôt, et une notice tierce sert précisément à ce que cette histoire soit
vérifiable après coup. Ce qui suit décrit ce qui a été emprunté, et ce qu'il en reste.

**Ce qui avait été emprunté — forme `pattern`.** La doctrine d'ingénierie agentique (revue par
pairs, développement piloté par les tests, idéation, développement par sous-agents) avait été
réécrite pour LCARS, sans copie de prose, sous la convention interne `**Dérivé de**` (`ADAPT` /
`ADOPT`). Le matériel vivait dans huit fichiers markdown de
`runtime/priv/catalogue*/cap_profile/` — cinq modop-bundles et trois subagent-templates. La
version précédente de cette notice en annonçait neuf : le compte avait déjà dérivé.

**Ce qui avait été emprunté — forme `dep`.** Le plugin `superpowers` pouvait être chargé au
runtime dans un pod via `LCARS_SKILLS_PLUGINS`. Il n'a jamais été redistribué par ce dépôt, et
**aucun cap-profile ne l'a jamais déclaré** : le mécanisme de chargement est générique et sert
d'autres skills (`card-revision`). Il reste ; le plugin n'a rien à y voir.

**Le retrait, et pourquoi.** Décision utilisateur : l'intégration avait été faite vite et le
matériel décrivait une architecture qui n'est pas la nôtre — les fragments faisaient lire des
`spec.md` / `plan.md` qu'un projet LCARS ne contient pas, et parlaient de « sous-agents » alors
qu'aucun n'est jamais lancé (le fragment était concaténé dans le prompt du rôle lui-même). Rien
n'était actif au moment du retrait : aucun bundle `optional` n'est jamais activé en production, et
les deux dernières déclarations vivantes (juges) avaient été débranchées le même jour.

Ce qui, dans ces fichiers, était de LCARS a été rapatrié dans le catalogue avant suppression : la
grille de sévérité (→ `sp_blocks/core/judge-verdict.md`) et le plancher mécanique conditionnel du
lot B (→ `sp_blocks/method/test-evidence-review.md`).

**Vérifier** : `grep -rn "Dérivé de.*superpowers" runtime/priv` — zéro résultat attendu.

Le corpus d'origine cite lui-même ses sources (Cialdini 2007, Meincke 2025) ; cette filiation
partait avec les fichiers dérivés.

---

## Compatibilité des licences

LCARS-fleet est sous **AGPL-3.0**. Les emprunts sont sous **Apache-2.0** et **MIT**, toutes deux compatibles avec l'AGPL-3.0 dans ce sens :

- **MIT → AGPL-3.0** : permissive, aucune restriction ajoutée.
- **Apache-2.0 → AGPL-3.0** : compatible avec la GPLv3 et l'AGPLv3, dans cette direction uniquement. Du code AGPL ne pourrait pas être reversé dans un projet Apache-2.0.

Le code vendoré sous Apache-2.0 conserve sa propre licence : la copier dans un projet AGPL ne la relicencie pas. Le fichier [`LICENSE.upstream`](runtime/vendor/token_saver/LICENSE.upstream) l'accompagne, et le sous-arbre reste identifiable comme tel dans l'arborescence (`vendor/`) et dans le [`.gitattributes`](.gitattributes) (`linguist-vendored`).

---

## Vérifier

La convention interne `**Dérivé de**` trace les filiations fichier par fichier :

```bash
grep -rn "Dérivé de" runtime/priv knowledge
```

Le code tiers copié est isolé sous `vendor/` et déclaré dans `.gitattributes` :

```bash
git check-attr linguist-vendored -- runtime/vendor/token_saver/src/core.py
```

---

*Ce document est tenu à jour à chaque nouvel emprunt. Un emprunt non déclaré ici est un bug — signalez-le.*
