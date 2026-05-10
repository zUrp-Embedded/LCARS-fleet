# PoC-02 — OAuth wizard WSL2/host

**Date** : 2026-04-20
**Dernière révision** : 2026-04-20
**Statut** : done — 7/9 PASS, 2 WARN configuration
**Référencé par** : `work/beyond/poc-plan.md §PoC-02`, `work/beyond/findings/2026-04-20-wsl2-interop-disabled-oauth.md`
**Version claude testée** : 2.1.114
**Branche** : `feature/poc-02-oauth-wsl`

## Hypothèse

Le flow `claude auth login` ouvre le browser Windows automatiquement via interop WSL2, crée `.credentials.json`, et la copie sécurisée vers `/home/private` se fait proprement.

## Méthode

Script `test_oauth.sh` qui :
- inspecte `/etc/wsl.conf` et le socket `/run/WSL/*_interop`
- lance `claude auth login` en PTY simulé (via `script -q -c`), kill après 7s, parse l'output
- vérifie permissions de `.credentials.json` existantes
- reproduit le pattern `umask 077; cp` dans un temp
- confirme `claude auth status` reconnaît des credentials copiées
- confirme `claude -p` fonctionne avec des credentials recopiées

## Résultats

| Test | Ce qu'on teste | PASS |
|---|---|---|
| T1 | Surface interop (socket + /init binfmt) | PASS |
| T2 | `claude auth login` imprime "Opening browser" + URL fallback | PASS |
| T3 | Interop effectivement actif | **WARN** — `[interop] enabled=false` |
| T4 | `.credentials.json` perms 600 | PASS |
| T5 | `umask 077; cp` donne 600 | PASS |
| T6 | `/home/private` accessible pour écriture | **WARN** — 700, owned lordzurp |
| T7 | Re-run détecte creds existantes (`auth status`) | PASS |
| T8 | Creds portables (copie fonctionnelle) | PASS |

## Finding T3 — interop désactivé

`/etc/wsl.conf` de l'instance contient explicitement :
```ini
[interop]
enabled=false
appendWindowsPath=false
```

Conséquences :
- `powershell.exe` n'est pas dans `$PATH` (normal)
- `/init` (binfmt Windows) est présent, `/run/WSL/*_interop` socket existe → **surface technique disponible**
- Mais avec `enabled=false`, `exec()` d'un `.exe` via binfmt échoue

Le flow attendu par la doctrine (`browser host auto-ouvert par PowerShell`) **ne peut pas marcher en pratique** dans cette config. Le binaire `claude` imprime bien `"Opening browser to sign in…"` puis la URL fallback — le user copie l'URL manuellement et l'ouvre côté Windows.

**Ce n'est pas un bug** du wizard : c'est cohérent avec l'isolation WSL de l'instance. Le corpus moon-shot (`beyond-chaine-install-v2.md`) doit être ajusté pour documenter que l'auto-open browser suppose `[interop] enabled=true`, et que la flotte actuelle tourne en mode "URL manuelle".

Finding formel : `work/beyond/findings/2026-04-20-wsl2-interop-disabled-oauth.md`. Décision proposée : **corpus patch** prochaine passe 5j (documentation), **pas de code patch** (comportement déjà correct côté claude).

## Finding T6 — /home/private

`/home/private/` appartient à `lordzurp:lordzurp` avec perms `700`. Le user `starfleet` ne peut ni lire ni écrire. La copie `.credentials.json` vers `/home/private` décrite dans `provisioning/deploy.d/v1/deploy-claude.sh` requiert `sudo` — ce qui est déjà le cas dans le script (il tourne via `fleet-auth.sh` appelé en root).

Pas un bug, juste un invariant implicite à documenter : le pattern `umask 077; cp … /home/private/.credentials.json` est obligatoirement root-invoqué.

## Ce qui n'a PAS été testé

- **Flow complet OAuth** (user clique, callback, token reçu, écriture disque) — nécessite interaction humaine, hors scope script automatique.
- **Browser host s'ouvre vraiment** — dépend de `[interop]=true` qui est `false` ici. Non reproductible sans reroll WSL avec interop on.
- **`fleet-auth.sh` root** — le wrapper pour tous les agents. Testé en production v1, hors scope PoC isolé.

## Livrables

- `test_oauth.sh` — harness reproductible
- `report.txt` (dans `/tmp/poc02-XXXX/`) — log dernière exécution
