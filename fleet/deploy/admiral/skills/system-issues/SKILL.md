---
name: system-issues
description: Liste la boîte de réception sysadmin — les issues error_system du dépôt ops et les PR d'outillage en attente de signature vers la branche sysadmin. À lancer en début de séance.
---

# system-issues — la boîte de réception d'admiral

Lance `~/.claude/skills/system-issues/list.sh`. Deux lectures, dans l'ordre :

1. **les issues `error_system`** du dépôt ops (`fleet/lcars`) — les défauts du système que la
   fleet a remontés (le détail est dans chaque ticket) ;
2. **les PR ouvertes vers `sysadmin`** — les demandes d'outillage des pods qui attendent la
   signature d'un admin (l'approbation se fait sur la forge, pas ici).

Le script fait **deux lectures d'un dépôt public**, avec le **jeton système** de la boîte
(`/home/private/<compte-système>.gitea_token`) — jamais le master. Mesuré : `fleet/lcars` est
public, et ses deux points d'entrée répondent même en anonyme. Aucune de ces lectures n'est
site-admin, donc aucune n'a besoin d'une autorité.

Ce skill ne vit QUE dans le `~/.claude` du siège (posé par le provisioning, jamais par le
catalogue). Ce n'est pas un privilège : **aucun siège n'en a**. La seule autorité de cette boîte est
le drapeau `is_admin` de la forge, demandé à l'instant du geste — et lire une boîte de réception
n'est pas un geste d'autorité.
