# Guide — Procédures de test qualifier

**Date** : 2026-03-21
**Dernière révision** : 2026-03-21
**Statut** : guide opérationnel
**Référencé par** : fleet/system-prompt/sources/roles/qualifier.md, sources/core/#2_qualite.md

---

## Principe de segmentation

L'instance qualifier opère dans son propre home WSL. Elle n'a **pas accès** à :
- `/local/LCARS/` (runtime fleet, home starfleet)
- Les homes des autres agents

Elle **a accès** à :
- Son propre home (`/home/qualifier/`)
- `/var/spool/fleet/inbox/qualifier/` (messages entrants)
- Ses scripts déployés dans `~/.local/bin/`

**Règle** : séparer explicitement les tests en deux blocs — ce que qualifier peut exécuter localement, et ce qui doit être escaladé.

---

## Structure d'une procédure de test

Chaque test a un ID (T1, T2…) et une valeur attendue explicite. Une procédure sans expected value est non vérifiable.

```markdown
### [engineer] Validate <artefact> — ACK required

<Description en 1 ligne de ce qui est testé et pourquoi.>

#### Tests qualifier-local (exécutables directement)

**T1 — <description>**
```bash
<commande>
# expected: <valeur attendue>
```

**T2 — ...**

#### Tests escaladés (chemins non accessibles)

Les tests suivants nécessitent des chemins hors scope qualifier.
Qualifier les escalade via `fleet-send.sh starfleet "<sujet>"` (escalade système) ou `fleet-send.sh engineer "<sujet>"` (escalade métier). Le destinataire vérifie et reporte.

- T_N: <description> — path: `/local/LCARS/<chemin>`
- T_M: <description>

#### Protocole de réponse

Répondre via : `fleet-send.sh engineer "QA result: <artefact>"`
- `PASS` si tous les tests locaux passent et les tests escaladés sont confirmés
- `FAIL — T<N>: observed <valeur> expected <valeur>` avec chaque test en échec
```

---

## Types de tests

### Qualifier peut exécuter (statiques/structurels)

| Type | Exemple |
|---|---|
| Existence fichier | `test -f ~/.local/bin/fleet-state.sh` |
| Frontmatter YAML | `grep "^name:" skill.md` |
| Présence de sections | `grep -c "^## Step" skill.md` |
| Absence de patterns dangereux | `grep -E "lordzurp\|LCARS-fleet" fichier.md` |
| Cohérence logique (lecture) | Review narratif — workflow complet, non-ambigu |
| Scripts déployés dans `~/.local/bin/` | Vérification présence et permissions |

### Hors scope (toujours escalader)

| Type | Raison |
|---|---|
| Chemins hors home qualifier | Non accessible |
| Exécution de scripts fleet avec side effects | Containment — voir `#12_starfleet-protocols.md` § Holodeck |
| Tests d'intégration (réseau, ports) | Hors scope + effets de bord |
| Lecture/écriture dans d'autres homes | Non accessible |

---

## Checklist pré-envoi

Avant d'envoyer une procédure à qualifier :

1. Chaque test a un ID (T1, T2...) et une valeur attendue explicite
2. Les tests sont classés en "qualifier-local" vs "escaladés"
3. La procédure ne demande pas d'exécuter du code modifiant l'état système
4. Les tests statiques couvrent : existence, structure, patterns interdits, logique
5. Le message est envoyé via `fleet-send.sh qualifier "Validate <artefact>"`

---

## Artefacts déclencheurs

Validation qualifier **obligatoire** avant deploy/push (défini dans `conventions.md` § Qualité et CI) :

1. Nouveaux skills `.claude/skills/*/SKILL.md`
2. Hooks nouveaux ou modifiés
3. Directives CLAUDE.md nouvelles ou modifiées
