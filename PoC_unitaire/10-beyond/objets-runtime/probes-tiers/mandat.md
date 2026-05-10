# probes-tiers

**Source** : `work/moon-shot/10-beyond/beyond-objets-runtime-v2.md` §4 "Probes"
**Date** : 2026-04-20
**Dernière révision** : 2026-04-20
**Statut** : DRAFT
**Référencé par** : `objets-runtime/README.md`

## Contrat

Trois tiers de probes, calqués sur Kubernetes (sans le trafic réseau) :

| Tier | Quand | Échec implique |
|---|---|---|
| **startup** | Une fois au boot | Composant refuse de démarrer (pas de mode dégradé pour startup) |
| **readiness** | Après startup | Composant en mode dégradé : API répond mais refuse le travail (spawn, requests) |
| **liveness** | Périodique (30s suggéré) | Alerte + action corrective (restart, kill pod) |

**Deux domaines** : hôte fleet-pilot + par pod. Chaque probe est binaire (True/False), indépendante, testable isolément.

## Observable

- Interface probe uniforme : fonction `() -> (bool, message_str)` pour chaque probe
- Tier déterminé par la classe de la probe, pas par son contenu
- Fleet-pilot orchestre : startup à t=0, readiness post-startup, liveness par interval

## Gaps à combler

- [GAP] classes de probes par tier (System.Startup, System.Readiness, System.Liveness, Pod.Startup, Pod.Readiness, Pod.Liveness)
- [GAP] impl-python chaque probe (déjà listées §3 ready : runtime_exists, specs_readable, etc. pour startup système)
- [GAP] orchestrateur : `run_startup_probes() -> dict[name, result]`, `schedule_liveness()`, `run_readiness_check()`
- [GAP] test : mocker chaque probe, vérifier que fleet-pilot prend la bonne décision (refus boot, mode dégradé, alerte+restart)

## Lien avec les unités existantes

- `ready-conjunction-of-probes/` (contrat-runtime-minimal) teste la conjonction des 6 startup système — probe niveau logique
- `boot-startup-probes/` (contrat-runtime-minimal) reste DRAFT, contiendra l'impl-python des 6 probes système
- Cette unité-ci concerne le **dispatch par tier** (startup vs readiness vs liveness), pas les probes individuelles
