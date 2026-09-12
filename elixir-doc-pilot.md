# Lot pilote — documentation Elixir

Base : `5c7f34121d2609ad4e187bb40775c0ac39343a51`, branche `codex/elixir-doc-cleanup`.
Travail limité aux trois sources du spawner dans ce clone. Aucun fichier du domaine `Fleet.Pilot` modifié.

## Mesures

| Source | Lignes avant → après | Commentaires et documentation avant → après |
|---|---:|---:|
| `runtime/lib/fleet/spawner.ex` | 827 → 577 | 399 → 149 |
| `runtime/lib/fleet/spawner/pod.ex` | 1 482 → 1 126 | 437 → 88 |
| `runtime/lib/fleet/spawner/supervisor.ex` | 46 → 27 | 25 → 6 |
| Total | 2 355 → 1 730 | 861 → 243 |

Réduction documentaire de 618 lignes (71,8 %), sans objectif chiffré préalable.
Les 1 222 lignes de code et déclarations restent identiques en nombre ; `@doc false` reste présent.

Comptage en lignes physiques : commentaires reconnus par `Code.string_to_quoted_with_comments/1`, blocs `@moduledoc` et `@doc` avec délimiteurs et blancs internes. Les blancs hors documentation sont séparés. Les `@spec`, `@type`, `@impl` et autres attributs fonctionnels sont classés avec le code. Aucun commentaire en fin de ligne de code, aucun `@typedoc` dans ce lot.

## Décisions représentatives

- **Conserver une contrainte de concurrence** : trois lignes à `Pod.start_link/1` expliquent pourquoi l’allocation doit rester dans le démarrage sérialisé par le superviseur. Suppression de la répétition dans la façade et de l’affirmation erronée selon laquelle cette fonction s’exécute dans le processus enfant.
- **Conserver une distinction de configuration** : deux lignes expliquent pourquoi une clé de skills absente sélectionne le catalogue tandis que `nil` désactive les skills.
- **Conserver un contrat de livraison** : les docs de `wake_pod/1` et `notify_pod/2` précisent que `:ok` ne prouve pas la livraison, ni même la réussite de l’écriture du flag. `Pod.TurnFlag.write/2` journalise les échecs mais retourne `:ok`.
- **Corriger la reprise** : supprimer « seul le recall reprend une session » et « uniquement si le snapshot est absent ». `recover_from_snapshot/3` appelle aussi `maybe_slot_resume/1` pour une ancienne époque de flotte. La doc du module décrit les deux chemins.
- **Corriger l’observation** : `snapshot_on_record?/2` constate seulement l’existence d’un fichier régulier. La précédente description promettait son effacement au kill ; le code écrit un état `:killed`, dont le nettoyage est distinct.
- **Préciser un succès partiel** : `reprovision_pipe_workspace/3` peut retourner `:ok` après un reset disque réussi et un `/clear` échoué. La documentation expose cette limite.
- **Supprimer les arguments d’autorité** : retirer la défense de la taille de `pod.ex`, les interdictions de refactorer, les récits de corrections et les calculs de capacité liés à un état ancien de la flotte.
- **Rapprocher le texte du code concerné** : retirer le paragraphe sur le fichier de mandat placé au-dessus de `kick_stop_reason/3` ; garder deux lignes utiles dans `materialize_mandate/1`.

## Validation

- Relecture indépendante par `gpt-5.6-terra`, effort `medium`, avec contexte neuf et sans ce bilan : aucune perte utile ou erreur nouvelle confirmée. Une ambiguïté mineure de `wake_pod/1` a été corrigée : `:unreachable` inclut le pod enregistré qui ne répond pas, comme le montrent `pod_info/2` et son test de timeout.
- Vérification reproductible depuis la racine : `elixir maintenance/elixir-doc-cleanup/verify_l00.exs` (compare les fichiers à la base fixe indiquée ci-dessus, y compris après commit).
- Parsing des trois versions avant/après avec le parseur Elixir : réussi.
- Comparaison des AST en neutralisant les métadonnées et les valeurs textuelles des seuls attributs documentaires : identiques. Les attributs fonctionnels, clauses, chaînes opérationnelles et `@doc false` sont préservés.
- `mix format --check-formatted lib/fleet/spawner.ex lib/fleet/spawner/pod.ex lib/fleet/spawner/supervisor.ex`, depuis `runtime/` : réussi.
- `git diff --check` : réussi.
- Aucun exemple `iex>` à supprimer ; aucune directive d’outillage identifiée dans les commentaires du lot.
- Validation complémentaire effectuée pendant L01, avec L00 présent : compilation et 88 tests ciblés réussis avant et après L01 (`canon_proof_test.exs`, `permanent_boot_test.exs`, `permanent_warden_test.exs`, `spawner_test.exs`). Ce résultat ne constitue pas une comparaison ExUnit avant/après L00.
- `MIX_ENV=test mix lcars.contracts.check`, avec L00 et L01 présents : 75 contrôles réussis, aucun échec.

## Constats à traiter séparément

Une seconde revue des informations uniques a rétabli deux éléments trop comprimés au premier passage : l’interdiction OTP d’émettre `next_event` depuis un callback d’entrée d’état (reproduite avec un test isolé sur l’OTP installé), et le dimensionnement du plafond global sur le pic cumulé des projets et des permanents. La valeur par défaut du contournement diagnostique `:allow_no_brief` est également explicitée. Les anciennes hypothèses chiffrées de charge ne sont pas réintroduites comme des faits actuels.

Les succès partiels de réveil et de reset décrits ci-dessus sont conservés, pas corrigés fonctionnellement. Leur acceptabilité relève d’un autre chantier.
L’ancien commentaire affirmant un manque de couverture de l’ordre checkpoint/teardown a été supprimé : ce déficit n’a pas été vérifié par mutation dans ce lot. La raison de l’ordre est conservée sans revendiquer une garantie de test.

Lot validé et enregistré dans un commit L00 dédié, avec ce bilan et son vérificateur. Aucune réintégration dans le dépôt partagé effectuée.
