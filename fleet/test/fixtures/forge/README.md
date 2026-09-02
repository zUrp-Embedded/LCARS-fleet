# Charges Gitea RÉELLES — la référence, et pourquoi elle existe

**Date** : 2026-09-02
**Image** : `gitea/gitea:1.26.1-rootless@sha256:4c4256497e2e237ddebdd30986c7ce52cb6f936b3e90c34bb9f4665714599f62`
**Provenance** : forge levée depuis `deploy/docker/forge-compose.yml`, digest vérifié sur le
conteneur lui-même (`docker inspect --format '{{.Image}}'`), pas déduit du tag.

## ⚠ Pourquoi ces trois fichiers existent

Le corpus de témoins de ce dépôt **fabrique des centaines de charges Gitea à la main**, et rien ne
les adosse à ce que la forge envoie vraiment. Chaque témoin construit exactement les champs que le
code lit *aujourd'hui* — donc un garde qui lirait un autre champ retombe sur son repli sans un mot.
Le `@moduledoc` de `test/support/pilot/forge_stubs.ex` raconte cette panne, vécue :

> *sans lui, `probe_state/4` retomberait sur son `:unknown` de garde et le mur de la sonde serait
> muet dans TOUTE la suite, silencieusement.*

Ces trois captures sont la seule source **non circulaire** pour savoir à quoi ressemble une réponse.
Elles ne sont pas des fixtures de test : ce sont la RÉFÉRENCE contre laquelle les fixtures se
calibrent, et le `Fleet.Forge.Payload` à venir (plan `beyond_#6/frontiere_forge.md`) en tirera ses
valeurs par défaut plutôt que de les inventer.

## Ce qu'elles ont déjà établi

- **Tous les champs que le runtime lit existent** — 14 sur `Issue`, 16 sur `PullRequest`. Aucune
  lecture inventée.
- **`assignee`, `milestone`, `pull_request`, `merged_at` valent `null`** quand ils ne sont pas
  renseignés : tout accès non gardé casse.
- **La spécification OpenAPI de cette version ne déclare AUCUN champ requis** — pas même `number`.
  Un lecteur ne peut donc s'appuyer sur la présence de rien.
- ⚠ **L'ordre des statuts CI est du plus ANCIEN au plus récent** (`statuses.json` : `id=1` puis
  `id=2`, même contexte). Un commentaire du dépôt affirmait l'inverse. `Client.CI` ne s'y fie pas
  — il prend `Enum.max_by(& &1["id"])` — mais un lecteur qui aurait cru la phrase et pris
  `List.first/1` aurait rendu le verdict du PREMIER job.

## Comment les refaire

```sh
cd fleet/deploy/docker
LCARS_DEVFORGE_PORT=23101 docker compose -f forge-compose.yml -p <à-toi> up -d
docker exec <à-toi>-gitea-1 gitea admin user create --username mesure \
  --password '<...>' --email mesure@localhost --admin --must-change-password=false
# puis : jeton via POST /api/v1/users/mesure/tokens, un dépôt, une issue, une branche
# (`new_branch_name`, PAS `name`), un fichier, une PR, deux statuts sur le même contexte.
```

⚠ **Ne pas mesurer sur le banc d'un autre.** La première version de ce constat a été prise sur un
banc voisin, qui a été purgé dans l'heure : la mesure n'était plus refaisable, et le contrôle
conteneur → digest est devenu impossible. Un banc à soi, ou rien.
