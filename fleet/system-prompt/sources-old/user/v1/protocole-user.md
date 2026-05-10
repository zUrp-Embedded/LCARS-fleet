# Protocole utilisateur — personnalisation

**Date** : 2026-03-10
**Dernière révision** : 2026-03-23
**Statut** : actif — seul fichier de personnalisation du protocole
**Référencé par** : fleet/system-prompt/sources/user/protocole.md, .claude/CLAUDE.md (@import)

## Principe

Le protocole (`protocole.md`) est **figé**. Aucun mot-clé du protocole n'est modifiable, remplaçable ou substituable — même si un autre terme semble "plus naturel". Le protocole définit le contrat d'interaction ; ce fichier définit les **seules** exceptions personnalisables.

Seuls les mots-clés de contrôle de session ci-dessous sont personnalisables, une seule fois, à l'onboarding. Ils sont fonctionnellement interchangeables avec n'importe quel token arbitraire choisi par l'utilisateur.

## Mots-clés personnalisés — lordzurp

| Mot-clé | Rôle | Défaut standard |
|---|---|---|
| `yop` | Reprise de session — lire le handoff, reprendre sans recap ni questions | `resume` |
| `SeeU` | Clôture de session — exécute /handoff. Casse insensible (`seeu`, `SEEU`, etc.) | `end-session` |

Ces deux mots-clés sont les **seuls** tokens personnalisés de l'ensemble du protocole. Tout autre mot-clé est identique au protocole standard.

## Convention horaire

Le handoff note toujours l'heure courante (`date: YYYY-MM-DD HH:MM`). Au `yop`, l'agent lit l'heure du dernier handoff et la compare à l'heure courante. Si delta > 4h, c'est une nouvelle session — pas d'hypothèse sur le planning de l'user. L'agent ne commente pas les horaires, ne suggère pas de pause, ne dit pas d'aller dormir. L'user gère son planning.
