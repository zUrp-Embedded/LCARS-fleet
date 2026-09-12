# Inventaire et découpage du nettoyage Elixir de runtime

État au 12 septembre 2026, dans le clone `LCARS-elixir-doc-cleanup`.
Base de comparaison : `5c7f34121d2609ad4e187bb40775c0ac39343a51`.

## Proposition

**82 lots de revue, destinés chacun à un commit documentaire.** L00 est le lot pilote (`1be48ca58`) ; les lots L01 à L81 couvrent le reste du corpus. L'avancement et les validations sont consignés dans les [bilans par lot](reviews/) et les commits `docs(...): Lxx`, plutôt que dans une seconde liste de statuts à maintenir ici. Un lot sans modification utile sera marqué examiné et ne produira pas de commit vide. Ce découpage n’autorise pas la suppression mécanique des commentaires inventoriés.

Les limites de préparation sont de **12 fichiers, 900 lignes documentaires existantes et 5 000 lignes source à lire par lot**. Le manifeste respecte ces trois limites. Le nombre de lignes documentaires mesure le matériau à évaluer, pas le futur diff : une réécriture peut produire à la fois des suppressions et des ajouts. Si un diff dépasse environ 1 200 lignes ajoutées/supprimées, ou mêle deux sujets distincts, le scinder avant commit. Aucun objectif de réduction en pourcentage.

Les regroupements suivent les domaines et les sous-ensembles du spawner, de Pilot, de MCP et des contrats Mix. Les paires source/test de même nom sont réunies lorsqu’elles appartiennent au même sujet. Les tests transversaux restent explicitement affectés à un lot ; leurs noms ne prouvent pas une correspondance exhaustive avec les modules. La lecture des appels et des tests pourra conduire à ajuster ces frontières avant de commencer un lot.

## Corpus mesuré

| Zone | Fichiers | Lignes physiques | Commentaires + documentation |
|---|---:|---:|---:|
| `runtime/lib/` | 290 | 77 002 | 27 883 |
| `runtime/test/` | 331 | 81 054 | 14 947 |
| `runtime/config/` | 3 | 1 183 | 742 |
| `mix.exs` et 3 fichiers de configuration cachés | 4 | 545 | 247 |
| **Total** | **628** | **159 784** | **43 819 (27,4 %)** |

Les fichiers `.ex` et `.exs` suivis par Git sont tous inclus, y compris `.credo.exs`, `.dialyzer_ignore.exs` et `.formatter.exs`. Aucun fichier Elixir suivi hors de `runtime/` dans cette base. Les dépendances, artefacts et fichiers non suivis ne font pas partie de l’inventaire.

Le volume documentaire initial se répartit en 26 197 lignes de commentaires `#` et 17 622 lignes d’attributs documentaires textuels. Les délimiteurs et blancs internes aux blocs documentaires sont inclus ; les blancs externes sont séparés. Le parseur distingue les commentaires des chaînes opérationnelles, des interpolations et des extraits de code contenus dans les fixtures. Les attributs non textuels (`@doc false`, métadonnées, expressions calculées) sont dénombrés séparément et ne sont pas présumés supprimables.

L’inventaire TSV conserve aussi les valeurs actuelles : après L00, 159 159 lignes physiques et 43 201 lignes documentaires. Les tableaux de dimensionnement ci-dessous utilisent **tous la base initiale**, pour ne pas comparer un domaine déjà nettoyé à des domaines intacts.

43 invites `iex>` sont présentes dans trois sources : `forge/protocol.ex` (27), `slug.ex` (11), `workflow/gates/predicate.ex` (5). Ce compte est un signal de revue des doctests, pas un nombre garanti de tests exécutés.

## Ordre et familles

Ordre de lecture proposé : terminer le spawner à partir du pilote, puis traiter les primitives et contrats consommés par les domaines de coordination, enfin les surfaces et l’outillage. Les déclarations `Boundary` et la carte `runtime/lib/fleet/README.md` servent de repères ; cette proposition ne prétend pas établir un graphe complet des appels ou des dépendances injectées. Les contrôles de contrats existants restent à exécuter pour chaque lot concerné même si leur propre nettoyage est prévu plus tard.

| Lots | Sujet | Fichiers | Lignes documentaires initiales |
|---|---|---:|---:|
| L00 | Pilote spawner déjà préparé | 3 | 861 |
| L01–L03 | Spawner : cycle de vie et supervision | 24 | 1 372 |
| L04–L06 | Spawner : provisioning et lancement | 25 | 1 500 |
| L07 | Spawner : identité et persistance | 12 | 673 |
| L08–L09 | Spawner : activité et résultats | 13 | 581 |
| L10 | Chemins et toolchain | 4 | 627 |
| L11–L13 | Primitives et formats partagés | 30 | 1 148 |
| L14–L16 | Catalogue et profils | 23 | 2 296 |
| L17–L18 | Identités et credentials | 15 | 884 |
| L19–L20 | Prompts et préparation des workspaces | 18 | 1 433 |
| L21–L23 | Événements et file de travail | 32 | 1 200 |
| L24–L25 | Analyse des conflits | 20 | 460 |
| L26–L30 | Forge : client et opérations | 29 | 2 716 |
| L31–L35 | Workflow : contrats et artefacts | 48 | 2 410 |
| L36–L37 | Projets : déclaration et maintenance | 16 | 1 226 |
| L38–L40 | Projets : onboarding | 23 | 1 901 |
| L41–L44 | MCP : transport et outils pods | 29 | 2 095 |
| L45–L47 | MCP : délégation métier | 27 | 1 757 |
| L48–L50 | Pilot : coordination, incidents et réveils | 27 | 1 696 |
| L51–L54 | Pilot : admission et réconciliation | 21 | 2 308 |
| L55 | Pilot : harnais de tests | 7 | 342 |
| L56–L58 | Pilot : dispatch et briefs | 16 | 1 860 |
| L59–L60 | Pilot : revue et remédiation | 15 | 1 351 |
| L61–L63 | Pilot : résultats et progression | 32 | 2 047 |
| L64–L65 | Pilot : fusion et conflits | 13 | 992 |
| L66–L67 | API et observation | 19 | 858 |
| L68–L70 | Démarrage et arrêt de la flotte | 23 | 1 425 |
| L71–L72 | Mix : commandes et catalogue | 14 | 804 |
| L73–L74 | Mix : contrats runtime et artefacts | 9 | 1 189 |
| L75 | Mix : sources de vérité et déclarations | 7 | 665 |
| L76 | Mix : contrats des outils | 5 | 575 |
| L77–L78 | Mix : infrastructure des contrôles | 8 | 973 |
| L79 | Infrastructure des tests | 10 | 436 |
| L80–L81 | Configuration et construction | 11 | 1 158 |

## Unités de commit

Les exemples servent à reconnaître le sujet ; **la liste exhaustive des fichiers est dans [batches.tsv](batches.tsv)**. Chaque fichier y apparaît exactement une fois. Les frontières sont une proposition de revue, pas une invitation à modifier un test sans lire ce qu’il vérifie.

| Lot | Repères dans le lot | Fichiers | Lignes à lire | Lignes documentaires |
|---|---|---:|---:|---:|
| L00 | `spawner.ex`, `pod.ex`, `supervisor.ex` | 3 | 2 355 | 861 |
| L01 | `application.ex`, `canon_proof.ex`, `permanent_boot.ex`… | 10 | 2 516 | 501 |
| L02 | `backend.ex`, `fs.ex`, `paths.ex`… | 12 | 4 709 | 837 |
| L03 | `restart_strategy_test.exs`, `seam_defaults_test.exs` | 2 | 62 | 34 |
| L04 | `launch_backend.ex`, `launcher_port_backend.ex`, `mcp_socket_provisioner.ex`… | 11 | 1 029 | 333 |
| L05 | `egress.ex`, `vendor.ex`, `launch_env.ex`… | 8 | 2 897 | 886 |
| L06 | `mcp_provision.ex`, `scaffold.ex`, `session_files.ex` | 6 | 808 | 281 |
| L07 | `boot_epoch.ex`, `recovery.ex`, `session_mint.ex`… | 12 | 2 236 | 673 |
| L08 | `completed_payload.ex`, `events.ex`, `kick.ex`… | 12 | 1 573 | 569 |
| L09 | `pod_kick_repl_up_test.exs` | 1 | 68 | 12 |
| L10 | `layout.ex`, `toolchain.ex` | 4 | 1 431 | 627 |
| L11 | `durable_log.ex`, `env_parse.ex`, `findings_wire.ex`… | 11 | 1 100 | 367 |
| L12 | `labels.ex`, `opts.ex`, `periodic_check.ex`… | 12 | 1 256 | 510 |
| L13 | `quiesce.ex`, `slug.ex`, `system_config.ex` | 7 | 914 | 271 |
| L14 | `cap_profile.ex`, `canonical_json.ex` | 4 | 2 942 | 761 |
| L15 | `catalog.ex`, `disallowed_tools.ex`, `image.ex`… | 12 | 2 385 | 758 |
| L16 | `catalogue.ex`, `schema_cache.ex` | 7 | 2 228 | 777 |
| L17 | `credentials.ex`, `authority.ex`, `forge_auth.ex`… | 11 | 1 291 | 443 |
| L18 | `role_token.ex`, `shell.ex` | 4 | 1 099 | 441 |
| L19 | `project_bootstrap.ex`, `phase.ex`, `sp_builder.ex` | 7 | 2 837 | 816 |
| L20 | `blocks.ex`, `composer.ex`, `image.ex`… | 11 | 2 201 | 617 |
| L21 | `event.ex`, `event_router.ex`, `application.ex`… | 12 | 1 444 | 318 |
| L22 | `listener.ex`, `signals_os.ex`, `unix_listener.ex`… | 12 | 1 434 | 348 |
| L23 | `in_flight.ex`, `task_queue.ex`, `application.ex`… | 8 | 1 931 | 534 |
| L24 | `conflict.ex`, `assemble.ex`, `classifier.ex`… | 12 | 1 526 | 341 |
| L25 | `one_side_change.ex`, `reorder_only.ex`, `same_change.ex`… | 8 | 803 | 119 |
| L26 | `forge.ex` | 2 | 479 | 145 |
| L27 | `client.ex` | 2 | 3 875 | 819 |
| L28 | `actions.ex`, `ci.ex`, `files.ex`… | 9 | 2 388 | 876 |
| L29 | `transport.ex`, `url_safe.ex`, `payload.ex` | 11 | 1 805 | 445 |
| L30 | `protocol.ex`, `write_spacing.ex` | 5 | 1 024 | 431 |
| L31 | `roster.ex`, `workflow.ex`, `brief_artifact.ex`… | 11 | 1 625 | 538 |
| L32 | `deliverable.ex`, `deliverable_gate.ex`, `gate.ex`… | 12 | 2 182 | 438 |
| L33 | `gates.ex`, `predicate.ex`, `git.ex`… | 12 | 3 076 | 740 |
| L34 | `ops_object.ex`, `ops_object_sync.ex`, `payload_guard.ex`… | 11 | 2 158 | 621 |
| L35 | `step_outputs.ex` | 2 | 278 | 73 |
| L36 | `project.ex`, `architect.ex`, `declaration.ex`… | 10 | 2 229 | 730 |
| L37 | `roles.ex`, `worktree_sync.ex` | 6 | 1 618 | 496 |
| L38 | `onboard.ex`, `adopt.ex`, `card.ex`… | 10 | 3 756 | 898 |
| L39 | `import.ex`, `lifecycle.ex`, `migration.ex`… | 11 | 3 080 | 885 |
| L40 | `onboard_migrate_test.exs`, `onboard_preflight_test.exs` | 2 | 430 | 118 |
| L41 | `mcp.ex`, `idempotency.ex`, `pod_socket_acceptor.ex`… | 9 | 2 434 | 580 |
| L42 | `pod_tools.ex`, `pod_resolver.ex` | 3 | 5 000 | 710 |
| L43 | `probe.ex`, `project_publish.ex`, `work_items.ex`… | 11 | 1 718 | 584 |
| L44 | `socket_warden.ex`, `supervisor.ex` | 6 | 826 | 221 |
| L45 | `delegation.ex`, `dependencies.ex`, `dependency_forge.ex`… | 12 | 1 735 | 499 |
| L46 | `forge_writer.ex`, `gate.ex`, `issue_pr.ex`… | 7 | 2 289 | 779 |
| L47 | `retirement.ex`, `scratchpad.ex`, `toolchain.ex`… | 8 | 1 808 | 479 |
| L48 | `pilot.ex`, `application.ex`, `arch_feed.ex`… | 12 | 3 031 | 845 |
| L49 | `incident_consumer.ex`, `incident_registry.ex`, `escalation.ex`… | 12 | 3 545 | 752 |
| L50 | `pod_feed.ex`, `wake_recovery.ex` | 3 | 412 | 99 |
| L51 | `offload.ex`, `pod_reaper.ex` | 4 | 777 | 185 |
| L52 | `poller.ex` | 2 | 2 935 | 805 |
| L53 | `admission.ex`, `backoff.ex`, `lease.ex`… | 10 | 2 284 | 892 |
| L54 | `poller_telemetry.ex` | 5 | 1 730 | 426 |
| L55 | `biz_catalogue_fixture.ex`, `cold_forge_stub.ex`, `dispatcher_bench.ex`… | 7 | 1 328 | 342 |
| L56 | `brief_builder.ex` | 3 | 1 644 | 469 |
| L57 | `step_dispatcher.ex`, `arch_escalation.ex`, `project_resolver.ex` | 6 | 3 057 | 785 |
| L58 | `spawn.ex` | 7 | 2 126 | 606 |
| L59 | `review_lifecycle.ex`, `ci_gate.ex`, `remediation.ex` | 6 | 2 765 | 872 |
| L60 | `conflict_ladder.ex`, `role_dispatch.ex`, `verdict_exception.ex` | 9 | 1 759 | 479 |
| L61 | `completion_outbox.ex`, `step_run_completer.ex`, `attestations.ex`… | 11 | 4 081 | 755 |
| L62 | `step_run_consumer.ex`, `gate_engine.ex`, `gatekeeper_escalation.ex`… | 12 | 3 766 | 814 |
| L63 | `verdict_correction.ex`, `workflow_map_nav.ex` | 9 | 2 567 | 478 |
| L64 | `conflict_apply.ex`, `conflict_probe.ex`, `conflict_report.ex`… | 9 | 3 087 | 895 |
| L65 | `merge_outcome.ex` | 4 | 374 | 97 |
| L66 | `api.ex`, `application.ex`, `build_info.ex`… | 12 | 2 125 | 505 |
| L67 | `deck.ex`, `view.ex`, `read_model.ex` | 7 | 1 396 | 353 |
| L68 | `admiral.ex`, `application.ex`, `audit_consumer.ex`… | 12 | 1 612 | 430 |
| L69 | `toolchain_reconciler.ex`, `application.ex`, `catalogue_deposits.ex`… | 8 | 2 731 | 834 |
| L70 | `catalogue_verify.ex` | 3 | 533 | 161 |
| L71 | `lcars.catalogue.roles.ex`, `lcars.catalogue.verify.ex`, `lcars.provenance.verify.ex`… | 12 | 2 802 | 765 |
| L72 | `slug_witness_test.exs`, `test_view_test.exs` | 2 | 234 | 39 |
| L73 | `artifact.ex`, `boot.ex`, `events.ex` | 3 | 1 556 | 485 |
| L74 | `runtime.ex` | 6 | 2 918 | 704 |
| L75 | `single_source.ex` | 7 | 2 588 | 665 |
| L76 | `tools.ex` | 5 | 2 189 | 575 |
| L77 | `lcars.contracts.check.ex`, `support.ex`, `tests.ex` | 6 | 3 309 | 859 |
| L78 | `test_corpora_check_test.exs`, `tests_corpus_walls_check_test.exs` | 2 | 455 | 114 |
| L79 | `os_probe_test.exs`, `authority_double.ex`, `barrier.ex`… | 10 | 908 | 436 |
| L80 | `config.exs`, `runtime.exs`, `test.exs` | 7 | 1 568 | 879 |
| L81 | `mix.exs`, `runtime_exs_guard_b_test.exs`, `seam_key_naming_test.exs`… | 4 | 704 | 279 |

## Procédure de chaque lot

1. Vérifier la base et les changements concurrents ; prendre le périmètre exact dans le manifeste. Lire les contrats exposés, les implémentations et les tests nécessaires aux affirmations documentaires.
2. Pour chaque suppression d’information non triviale, décider explicitement : déjà exprimée dans le code, conservée à un emplacement précis, périmée avec preuve, ou sans utilité actuelle justifiée. Une information unique dont l’utilité reste plausible impose une investigation, pas une suppression par défaut. Les notes détaillées servent à la revue, sans réintroduire les récits supprimés dans les sources.
3. Modifier uniquement les commentaires et attributs documentaires autorisés. Préserver licences, directives, chaînes de prompts, exemples et fixtures opérationnels. Une correction fonctionnelle découverte devient un chantier séparé.
4. Confier la revue des informations utiles et uniques à un sous-agent indépendant `gpt-5.6-terra`, effort `medium`, en lecture seule. Il reçoit le périmètre, le diff et les critères, avec un contexte neuf sans l’argumentaire de l’auteur. Il vérifie les pertes utiles, les affirmations nouvelles inexactes et les contrats ambigus, puis rend des constats courts avec preuves. L’auteur vérifie les signalements et corrige ; les incertitudes complexes font l’objet d’une analyse ciblée. C’est un contrôle distinct de l’identité du code, rendu nécessaire par les deux omissions corrigées dans L00.
5. Comparer les AST hors documentation et positions ; vérifier formatage, directives et doctests. Exécuter les tests/contrôles pertinents, notamment les contrôles qui inspectent le texte source. Ne pas présenter un contrôle non exécuté comme réussi. Préparer les dépendances dans ce clone avant les lots nécessitant la compilation.
6. Relire la taille et la cohérence du diff, puis commiter uniquement les chemins du lot. Exemple : `docs(spawner): L07 clarify session recovery and persistence`. Noter le commit, les mesures, les contrôles et les éventuels constats séparés dans un suivi succinct.

Les fichiers géants restent des lots de revue prudents même lorsqu’ils ont peu de prose : `test/fleet/mcp/pod_tools_test.exs` compte 3 158 lignes et `test/fleet/spawner/pod_test.exs` 2 781. Découper leur nettoyage par section si la lecture ou le diff devient trop lourd ; ne pas refactorer le fichier pour faciliter ce chantier documentaire.

Le plan, les inventaires et leurs outils sont enregistrés dans un commit de préparation distinct des commits documentaires. Les colonnes « current » des TSV sont la photographie après L00 ; les bilans par lot consignent les résultats ultérieurs.

## Fichiers et reproduction

- [inventory.tsv](inventory.tsv) : métriques de chaque fichier, base et état courant.
- [batches.tsv](batches.tsv) : affectation exhaustive des 628 fichiers aux lots.
- [batch-summary.tsv](batch-summary.tsv) : métriques par lot.
- [base-commit.txt](base-commit.txt) : commit mesuré.
- [inventory.exs](inventory.exs) et [plan_batches.py](plan_batches.py) : scripts sans dépendances de projet.

Depuis la racine du clone :

```sh
elixir maintenance/elixir-doc-cleanup/inventory.exs
python3 maintenance/elixir-doc-cleanup/plan_batches.py
```

Le premier script mesure HEAD et le working tree ; le second régénère les TSV des lots et vérifie la couverture sans doublon. Après évolution de HEAD, les mesures et le découpage régénérés décriront cette nouvelle base : conserver le manifeste validé pour stabiliser les identifiants de lot, et réviser ce document explicitement si le périmètre change.
