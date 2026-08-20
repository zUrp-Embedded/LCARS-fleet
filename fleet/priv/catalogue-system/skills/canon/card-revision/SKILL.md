---
name: card-revision
description: Réviser la carte de validation d'un projet EXISTANT — l'humain choisit, l'agent conseille, la justification est obligatoire, les tickets déjà routés gardent leur carte.
---

# card-revision — réviser la carte d'un projet existant

La carte d'un projet est sa déclaration de criticité : elle nomme le jury, le pipeline, le
niveau d'exigence. Elle a été gravée à la création — ce skill est le chemin de RÉVISION
(BL-6-29) : un PoC C0 devenu sérieux mérite un vrai jury, un projet clos peut redescendre.

## La doctrine, avant le geste

- **Le choix de carte EST la déclaration de criticité, et il appartient à l'HUMAIN.** Tu
  présentes, tu éclaires, tu ne décides jamais. Un choix hors-matrice est ACCEPTÉ (l'humain a
  le dernier mot) — il sera loggé fort, pas bloqué.
- **La justification est OBLIGATOIRE** : c'est le POURQUOI de la révision, committé avec la
  déclaration dans le dépôt du projet — l'historique git est le registre. Une révision sans
  motif est exactement la mutation non tracée que la fleet interdit.
- **Les routes déjà gravées ne re-routent PAS.** Le burn est per-ticket : un ticket en vol
  garde le contrat sous lequel il est parti. La révision vaut pour les tickets FUTURS —
  dis-le à l'humain au moment du geste, c'est la surprise classique.

## Le déroulé

1. **Présente le catalogue** : `list_workflow_cards`. Montre la `presentation` de chaque carte
   VERBATIM (c'est sa voix), avec `applicable_intensity` et `jury`. Si l'humain donne des
   éléments de cadrage (tension secteur ? ça coupe des doigts ? durée de vie ?), tu peux
   pré-filtrer et conseiller — rubber-duck, jamais évaluateur.
2. **Recueille le choix et le pourquoi.** Les deux, dans les mots de l'humain. Reformule le
   pourquoi en une phrase et fais-la valider : c'est elle qui part au commit.
3. **Exécute** : `project_revise_card` avec `full_name`, `workflow_map` (la carte choisie),
   `justification` (la phrase validée), et `intensity_level` si l'humain en a déclaré un.
4. **Relaie le résultat** : `outcome` `revised` (la protection de branche s'est re-taillée
   d'elle-même sur le jury de la nouvelle carte) ou `unchanged` (déclaration identique,
   no-op honnête). Et répète la sémantique des tickets en vol (point doctrine 3).

## Refus que tu verras, et ce qu'ils veulent dire

- `{:unknown_card, _}` — la carte nommée ne charge nulle part : une faute de frappe, pas un cas à
  contourner. Re-présente le catalogue.
- `{:card_in_another_catalogue, nom, catalogues}` — la carte existe, mais **pas dans le catalogue de
  ce projet**. Ce n'est pas une faute de frappe et ce n'est pas à toi de trancher : le catalogue fixe
  l'org du projet pour sa vie entière. Sur une **création**, l'oubli est presque toujours l'argument
  `catalogue` — la liste nomme le catalogue de chaque carte, passe les deux ensemble. Sur une
  **révision**, le projet existe déjà : sa carte doit venir de SON catalogue, et une carte d'ailleurs
  n'est pas une option — remonte à l'humain.
- `{:card_load_failed, nom, message}` — la carte **existe bien** dans le catalogue de ce projet, et
  elle ne se charge pas : YAML illisible, schéma invalide, graphe invalide. Ce n'est pas une faute
  de frappe, et ce n'est pas à toi de le réparer — un catalogue cassé se répare par qui le
  maintient, jamais en choisissant une autre carte. Remonte le `message` tel quel : il nomme
  exactement ce qui bloque.
  *(Ce refus était indiscernable de `{:unknown_card, _}` jusqu'au 2026-08-20 : toute levée du
  chargeur ressortait sous ce seul nom, donc une carte CASSÉE s'annonçait comme une carte
  INEXISTANTE — et on cherchait une faute de frappe qui n'existait pas.)*
- `{:card_push_failed, _}` — la forge a refusé la traversée : rien n'a changé, la règle de
  protection est restaurée. Réessaie ou remonte à l'humain.
- `justification` absente — le refus est voulu. Il n'y a pas de révision sans pourquoi.
