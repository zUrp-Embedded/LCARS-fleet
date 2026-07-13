# Docker — quickstart

**Date** : 2026-03-21
**Dernière révision** : 2026-03-30
**Statut** : guide opératoire
**Référencé par** : #00_index.md

> Déploiement Docker minimal. Utile pour test, CI, ou évaluation rapide. Ce n'est pas le mode principal de LCARS.

---

## Démarrage

```bash
git clone git@github.com:<user>/LCARS-fleet.git
cd LCARS-fleet
docker compose build
ANTHROPIC_API_KEY=... docker compose run --rm lcars
```

Premier lancement :
- onboarding dans le conteneur

Lancements suivants :
- `claude --resume`

---

## Environnement

| Variable | Requis | Usage |
|---|---|---|
| `ANTHROPIC_API_KEY` | oui | auth modèle |
| `GH_TOKEN` | non | opérations GitHub |
| `GIT_USER_NAME` / `GIT_USER_EMAIL` | non | identité git |
| `LCARS_REPO` | non | fork ou repo alternatif |

---

## Persistance

| Volume | Rôle |
|---|---|
| `./claude-home` | auth, settings, memory |
| `./ready-room` | artefacts et échanges user/fleet |

Sans volume, chaque exécution repart de zéro.

---

## Limites par rapport à WSL

Docker ici sert surtout :
- au test
- à la CI
- à l'évaluation rapide

Ce qu'il ne remplace pas bien :
- la fleet multi-instances complète
- l'expérience WSL native
- certains chemins d'intégration hôte

Si tu veux le comportement LCARS complet, vise le déploiement WSL.

---

## Lire ensuite

- [ONBOARDING.md](ONBOARDING.md)
- [#23_provisioning.md](#23)
