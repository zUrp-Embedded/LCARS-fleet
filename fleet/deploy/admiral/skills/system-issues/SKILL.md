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

Le script lit le master token sur le disque (`/home/private/forge-master.token`) : il ne
fonctionne que depuis une session qui peut le lire. Aucun pod ne le peut — c'est voulu, et ce
skill ne vit QUE dans le `~/.claude` du siège (posé par le provisioning, jamais par le catalogue).
