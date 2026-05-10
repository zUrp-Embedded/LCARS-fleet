# Plan — Renommage architect → engineer

## Contexte

L'instance fleet autonome s'appelle "architect" alors que l'instance interactive s'appelle
"architect". La confusion est systématique dans les logs, post-mortems et directives.
Renommer "architect" → "engineer" lève l'ambiguïté.

**Contrainte WSL** : la distro Windows reste nommée "Architect" (wsl-name: Architect,
chemin /home/wsl-root/#2_Home/Architect/). Tous les paths Windows qui la référencent
restent inchangés. Seuls les identifiants logiques changent.

**Branche dédiée** : `refactor/engineer` (intervention multi-fichiers significative).

---

## Ce qui change / ce qui ne change pas

| Élément | Avant | Après |
|---------|-------|-------|
| CLAUDE_AGENT_NAME | `architect` | `engineer` |
| tmux window | `5:architect` | `5:engineer` |
| IPC channel file | `to-engineer.md` | `to-engineer.md` |
| Handoff file | `architect-handoff.md` | `engineer-handoff.md` |
| Script provisioning | `post-install-architect.sh` | `post-install-engineer.sh` |
| fleet.yaml id/instance-type | `architect` | `engineer` |
| WSL distro Windows | `Architect` | **inchangé** |
| Chemin `#2_Home/Architect/` | — | **inchangé** |
| `fleet.yaml wsl-name` | `Architect` | **inchangé** |
| `architect` partout | — | **inchangé** |
| `architecture` (mot doc) | — | **inchangé** |

---

## Commits

### Commit A — Scripts fleet + Python + YAML (LOW, push direct)

**`fleet/fleet-monitor.py`**
- INSTANCE_NAMES set : `"architect"` → `"engineer"`
- HANDOFF_TO_INSTANCE : `"to-engineer": "architect"` → `"to-engineer": "engineer"`
- DIRECTIONAL_WAKE si présent : même substitution
- `instance_ids` list, `Layout(name=...)`, `instances["architect"]` assignments
- `dispatch_notify` : condition `architect` dans fire_wake appel
- `arch_file = HANDOFFS_DIR / "to-engineer.md"` → `"to-engineer.md"`
- Commentaires

**`fleet/fleet-hub.py`**
- INSTANCE_JSONL_DIRS : clé `"architect"` → `"engineer"`
- HANDOFF_FILES : `"architect": "architect-handoff.md"` → `"engineer": "engineer-handoff.md"`
- DIRECTIONAL : `"to-engineer": "to-engineer.md"` → `"to-engineer": "to-engineer.md"`

**`fleet/wake-instance.sh`**
- Pane mapping dict : `["architect"]="$SESSION:architect"` → `["engineer"]="$SESSION:engineer"`
- Condition `[[ "$INSTANCE" == "architect" ]]` → `"engineer"`
- `CLAUDE_AGENT_NAME=architect` → `engineer`

**`fleet/fleet-launch.sh`**
- `tmux new-window ... -n "architect"` → `-n "engineer"`
- `tmux send-keys ... CLAUDE_AGENT_NAME=architect ...` → `engineer`
- Commentaires (garder lignes "architect" intactes)

**`fleet/fleet-notify.sh`**
- Regex validation : `architect` → `engineer` (garder `architect` intact)

**`fleet/fleet-doctor.sh`**
- `EXPECTED_INSTANCES` : `architect` → `engineer`
- `CHANNELS` : `to-engineer.md` → `to-engineer.md`

**`fleet/light_off.sh`**
- `WORKERS` array, `WORKER_PANE` map

**`fleet/fleet-check-coherence.sh`**
- `TO_ARCHITECT` variable → `TO_ARCHITECT_FLEET`
- Path `to-engineer.md` → `to-engineer.md`
- Garder `$HOMES_ROOT/Architect/` (chemin Windows, inchangé)

**`fleet/fleet.yaml`**
- `id: architect` → `engineer`
- `instance-type: architect` → `engineer`
- `wsl-name: Architect` → **inchangé**

**`fleet/starfleet-notes-check.sh`**, **`fleet/handoff-trim.sh`**
- Références `to-engineer.md` → `to-engineer.md`

**`deploy.sh`**
- `"$HOMES_ROOT/architect/.claude"` → `"$HOMES_ROOT/Architect/.claude"` (majuscule = nom Windows réel)
  Note: vérifier le cas actuel — si c'est déjà `Architect` laisser tel quel, si c'est `architect` corriger
- Model map clé `"architect"` → `"engineer"`
- Loop `for instance in ... architect ...` → `engineer`

**`toolbox/backup-wsl.sh`**
- `INSTANCES` array

**`toolbox/apply-headers.py`**
- Clé `"provisioning/wsl2/post-install-architect.sh"` → `"post-install-engineer.sh"`

---

### Commit A-bis — git mv post-install-architect.sh (LOW, même push que A)

```bash
git mv provisioning/wsl2/post-install-architect.sh \
       provisioning/wsl2/post-install-engineer.sh
```

Mettre à jour les références au nom de fichier dans :
- `provisioning/wsl2/post-install.sh` : `MODULE=` appel
- `provisioning/wsl2/wsl-setup.sh` : validation type, messages d'erreur
- `provisioning/linux/deploy-fleet.sh` : `ROLES_ORDER`, conditions
- `provisioning/mac/deploy-fleet.sh` : idem
- `install.sh` : condition `!= "architect"` → `!= "engineer"`
- `insights-fr.md`, `insights-en.md` : header `post-install-architect.sh`

---

### Commit B — home_claude_CLAUDE*.md (HIGH → QA obligatoire)

Fichiers :
- `home_claude_CLAUDE.md` : scope **architect** et **architect**, liste handoff files,
  règle push-github `architect(-lead)`. Garder "architect" intacts.
- `home_claude_CLAUDE-qualifier.md` : référence `to-engineer.md` et escalade toolkit
- `home_claude_CLAUDE-builder.md` : exemple fleet-blocker

Staging QA : copier les sections modifiées dans `/home/commons/qualifier-staging/`.

---

### Commit C — Renommer fichiers IPC live (opérationnel, flotte à l'arrêt)

Les fichiers `/home/commons/handoff/to-engineer.md` et `architect-handoff.md` sont lus/écrits
par les instances actives. Les renommer à chaud casse les instances en cours.

Séquence (flotte arrêtée via light_off.sh) :
```bash
cp /home/commons/handoff/to-engineer.md \
   /home/commons/handoff/to-engineer.md
cp /home/commons/handoff/architect-handoff.md \
   /home/commons/handoff/engineer-handoff.md
# Conserver les anciens en .bak jusqu'à validation
mv /home/commons/handoff/to-engineer.md \
   /home/commons/handoff/to-engineer.md.bak
mv /home/commons/handoff/architect-handoff.md \
   /home/commons/handoff/architect-handoff.md.bak
```

Supprimer les .bak après premier boot fleet OK.

---

### Commit D — Documentation (LOW, push direct)

- `README.md`, `ONBOARDING.md`, `DIRECTIVES.md`
- `insights-fr.md`, `insights-en.md`
- `memory/ipc-protocol.md`, `memory/builder-rules.md`
- `docs_and_plans/guides_FR/architecture-lcars.md` et équivalent EN
- `docs_and_plans/guides_FR/design-history.md` et équivalent EN
- `docs_and_plans/guides_FR/qualifier-test-procedure.md` et équivalent EN
- `docs_and_plans/work/todo/lead-architect-overlap-detection.md`
- `docs_and_plans/drift-register.md`

---

## Ordre d'exécution et push

| Étape | Contenu | Danger | Action |
|-------|---------|--------|--------|
| 1 | Créer branche `refactor/engineer` | — | git checkout -b |
| 2 | Commit A + A-bis | LOW | push sur branche |
| 3 | deploy.sh | — | distribuer avant de toucher les handoffs |
| 4 | Commit B | HIGH | to-qualifier → ACK → push |
| 5 | Commit C | Opérationnel | flotte arrêtée, cp+mv handoffs live |
| 6 | Commit D | LOW | push |
| 7 | PR ou merge main | — | `/push-github` |

---

## Vérification end-to-end

1. `fleet-launch.sh` → tmux window `5:engineer` visible
2. `CLAUDE_AGENT_NAME=engineer` dans le pane
3. `fleet-monitor.py` dashboard affiche "engineer" (pas "architect")
4. `fleet-notify.sh engineer "test"` → validation OK, pas d'erreur regex
5. `to-engineer.md` créé dans `/home/commons/handoff/`, fleet-monitor lit le bon fichier
6. `post-install-engineer.sh` invoqué correctement depuis `post-install.sh`
7. Boot fleet complet : aucune référence à "architect" seul dans les logs de démarrage
