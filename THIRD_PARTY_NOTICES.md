# Third-Party Notices

**Date** : 2026-08-04
**Dernière révision** : 2026-08-06
**Statut** : actif — recensement des emprunts externes (Apache-2.0 §4)
**Référencé par** : `fleet/runtime/vendor/*/VENDOR.md`

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
| [token-saver](https://github.com/ppgranger/token-saver) | ppgranger | Apache-2.0 | `import` | `fleet/runtime/vendor/token_saver/` |
| [wshobson/agents](https://github.com/wshobson/agents) | wshobson et contributeurs | MIT | `import` | `knowledge/wshobson-agents/` |
| [GitWand](https://github.com/devlint/GitWand) | devlint | MIT | `recode` | `fleet/runtime/lib/fleet/conflict.ex` |
| [superpowers](https://github.com/obra/superpowers) | Jesse Vincent | MIT | `pattern` + `dep` | `fleet/runtime/priv/catalogue/cap_profile/canon/` |

---

## 1. token-saver — `import`

- **Source** : https://github.com/ppgranger/token-saver
- **Auteur** : ppgranger
- **Licence** : Apache License 2.0 — texte intégral conservé en [`fleet/runtime/vendor/token_saver/LICENSE.upstream`](fleet/runtime/vendor/token_saver/LICENSE.upstream)
- **Version reprise** : v2.6.3, commit `098873e04c6c49cbdc25c1c5f795986f5f170f16` (2026-06-02)

**Ce qui est repris** : les répertoires `src/`, `scripts/` et `tests/` — 67 fichiers Python, moteur de compression d'output CLI et ses 36 processeurs spécialisés.

**Ce qui ne l'est pas** : `installers/`, `.claude-plugin/`, `antigravity/`, `bin/`, `docs/`.

**Modifications apportées au code repris : aucune.** Le sous-arbre est une copie strictement identique à l'amont. Les correctifs et l'adaptation LCARS vivent dans des fichiers séparés (`adapter.py`, `lcars_*.py`), hors du sous-arbre. Ce choix sert autant la conformité — Apache-2.0 §4(b) impose de signaler les fichiers modifiés, il n'y en a aucun — que la maintenance : la mise à jour amont est une re-copie, sans patch à rejouer.

**Détail complet** : [`fleet/runtime/vendor/token_saver/VENDOR.md`](fleet/runtime/vendor/token_saver/VENDOR.md) — provenance, découpage, correctifs, procédure de suivi amont.

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
- **Emplacement** : `fleet/runtime/lib/fleet/conflict.ex` (135 lignes, Elixir)

**Aucune ligne de code n'a été copiée.** Le moteur d'origine est en TypeScript ; LCARS tourne sur la BEAM. Le cœur déterministe de résolution de conflits (analyse, huit motifs triviaux, diff LCS, score, trace de décision, assemblage) a été **réimplémenté en Elixir** à partir de la lecture du code source.

La périphérie du projet d'origine — résolveurs sensibles au format, fusion structurelle par AST, repli LLM, interface MCP, application de bureau — a été délibérément écartée après audit.

Le module porte la mention de sa filiation dans son `@moduledoc`. Le travail dérive d'une lecture attentive d'un travail publié : nous le déclarons, même si la MIT n'impose rien pour une réimplémentation.

---

## 4. superpowers — `pattern` et `dep`

- **Source** : https://github.com/obra/superpowers
- **Auteur** : Jesse Vincent
- **Licence** : MIT

**Forme `pattern`** — la doctrine d'ingénierie agentique (revue de code par pairs, développement piloté par les tests, idéation, développement par sous-agents) a été **entièrement réécrite** pour LCARS. Aucune prose n'est copiée : un prompt système ne se traduit pas, il se réécrit.

Neuf fichiers de `fleet/runtime/priv/catalogue/cap_profile/canon/` portent l'attribution explicite de leur source via la convention interne `**Dérivé de**`, avec la mention `ADAPT` (réécrit) ou `ADOPT` (repris tel quel dans l'esprit).

**Forme `dep`** — le plugin `superpowers` lui-même peut être chargé à l'exécution dans les pods de la fleet, via la variable `LCARS_SKILLS_PLUGINS`. Il n'est **pas redistribué** par ce dépôt : il est récupéré depuis sa source d'origine, à une version épinglée.

Le corpus d'origine cite lui-même ses propres sources — notamment les travaux de Cialdini (2007) et Meincke (2025) sur les principes de persuasion. Cette filiation est conservée dans nos fichiers dérivés.

---

## Compatibilité des licences

LCARS-fleet est sous **AGPL-3.0**. Les emprunts sont sous **Apache-2.0** et **MIT**, toutes deux compatibles avec l'AGPL-3.0 dans ce sens :

- **MIT → AGPL-3.0** : permissive, aucune restriction ajoutée.
- **Apache-2.0 → AGPL-3.0** : compatible avec la GPLv3 et l'AGPLv3, dans cette direction uniquement. Du code AGPL ne pourrait pas être reversé dans un projet Apache-2.0.

Le code vendoré sous Apache-2.0 conserve sa propre licence : la copier dans un projet AGPL ne la relicencie pas. Le fichier [`LICENSE.upstream`](fleet/runtime/vendor/token_saver/LICENSE.upstream) l'accompagne, et le sous-arbre reste identifiable comme tel dans l'arborescence (`vendor/`) et dans le [`.gitattributes`](.gitattributes) (`linguist-vendored`).

---

## Vérifier

La convention interne `**Dérivé de**` trace les filiations fichier par fichier :

```bash
grep -rn "Dérivé de" fleet/runtime/priv knowledge
```

Le code tiers copié est isolé sous `vendor/` et déclaré dans `.gitattributes` :

```bash
git check-attr linguist-vendored -- fleet/runtime/vendor/token_saver/src/core.py
```

---

*Ce document est tenu à jour à chaque nouvel emprunt. Un emprunt non déclaré ici est un bug — signalez-le.*
