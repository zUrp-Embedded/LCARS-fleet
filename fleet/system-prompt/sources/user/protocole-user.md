# Protocole utilisateur — personnalisation

**Date** : 2026-03-10
**Dernière révision** : 2026-07-30
**Statut** : actif — seul fichier de personnalisation du protocole
**Référencé par** : `.claude/CLAUDE.md` (`@import`), déployé en `<home>/sp-sources/user/` par
`deploy-claude.sh`

## Principe

Le protocole d'interaction est **figé**. Aucun mot-clé n'est modifiable, remplaçable ou
substituable — même si un autre terme semble « plus naturel ». Le protocole définit le contrat ;
ce fichier définit les **seules** exceptions personnalisables.

Seuls les mots-clés de contrôle de session ci-dessous sont personnalisables, une seule fois, à
l'onboarding. Ils sont fonctionnellement interchangeables avec n'importe quel token arbitraire
choisi par l'utilisateur.

## Mots-clés personnalisés — lordzurp

| Mot-clé | Rôle | Défaut standard |
|---|---|---|
| `yop` | Reprise de session — lire le handoff, reprendre sans recap ni questions | `resume` |
| `SeeU` | Clôture de session — exécute `/handoff`. Casse insensible (`seeu`, `SEEU`, etc.) | `end-session` |

Ces deux mots-clés sont les **seuls** tokens personnalisés de l'ensemble du protocole. Tout autre
mot-clé est identique au protocole standard.

⚠ Ces mots-clés valent pour une instance **interactive**. Un pod worker de la fleet ne lit pas ce
fichier : il reçoit `priv/sp_builder/sp_drafts/protocole-user-worker.md`, dont le déclencheur du
cycle work-item s'appelle `engage` — protocole machine, non personnalisable. Les deux noms sont
distincts précisément pour que les deux contrats ne puissent plus se confondre.

## Convention horaire

Le handoff note toujours l'heure courante (`date: YYYY-MM-DD HH:MM`). Au `yop`, l'agent lit l'heure
du dernier handoff et la compare à l'heure courante. Si delta > 4 h, c'est une nouvelle session —
pas d'hypothèse sur le planning de l'user. L'agent ne commente pas les horaires, ne suggère pas de
pause, ne dit pas d'aller dormir. L'user gère son planning.
