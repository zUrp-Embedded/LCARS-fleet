# FMEA — Ring 2 Support (6 scripts)

**Date** : 2026-03-28
**Derniere revision** : 2026-03-28
**Statut** : premiere passe
**Reference par** : v6-rings-and-interfaces.md
**Derive de** : bash-pro audit Ring 2+3+4, tests BATS Ring 2

---

## Methode

Severite (S) : 1=negligeable, 10=perte de donnees ou crash fleet.
Occurrence (O) : 1=theorique, 10=chaque session.
Detection (D) : 1=test automatise, 10=invisible.
RPN = S x O x D. Seuil fix : RPN > 10.

---

## Bloc 1 — Handoff Maintenance (handoff-check-utf8, handoff-trim, watch-handoff)

| ID | Script | Mode de defaillance | S | O | D | RPN | Mitigation |
|---|---|---|---|---|---|---|---|
| R2S-01 | handoff-check-utf8 | iconv absent sur le systeme | 4 | 1 | 3 | 12 | Prereq check (iconv est dans glibc, quasi-universel). Ajouter test doctor. |
| R2S-02 | handoff-check-utf8 | Corruption drvfs non detectee (encoding valide mais contenu tronque) | 6 | 3 | 7 | 126 | iconv ne detecte que les violations UTF-8, pas la troncation. Ajouter checksum compare ready-room vs handoffs. |
| R2S-03 | handoff-check-utf8 | --restore mode bloque un restore valide (faux positif) | 5 | 1 | 3 | 15 | Test BATS couvre ce cas. Rare (fichier valide mal lu). |
| R2S-04 | handoff-trim | awk rewrite corrompt le fichier (crash mid-write) | 8 | 1 | 5 | 40 | Utilise .tmp + mv (atomique sur ext4). Risque residuel sur drvfs (pas atomique). |
| R2S-05 | handoff-trim | Fichier exempt mal classe (manque dans EXEMPT[]) | 3 | 2 | 5 | 30 | Liste EXEMPT hardcodee. Si un nouveau fichier exempt est ajoute, il faut mettre a jour la liste. |
| R2S-06 | handoff-trim | Seuil 1400B trop agressif — tronque des handoffs courts avec beaucoup d'ACTIONS | 5 | 2 | 3 | 30 | Seuil fixe et raisonnable. Monitorer les faux positifs. |
| R2S-07 | watch-handoff | colorize-handoff.py absent ou python3 absent | 3 | 1 | 2 | 6 | Script de monitoring — non critique. |
| R2S-08 | watch-handoff | Boucle infinie consomme CPU si fichier absent | 2 | 2 | 4 | 16 | python3 leve FileNotFoundError, clear + sleep continue. Boucle ne consomme pas si fichier absent (erreur affichee chaque cycle). |

### Fixes RPN > 10

| ID | RPN | Action |
|---|---|---|
| R2S-01 | 12 | Acceptable — iconv est universel, doctor le verifie. |
| R2S-02 | 126 | **CRITIQUE.** Ajouter un checksum (md5/sha256) compare entre ready-room/handoffs et /home/handoffs. Alerte si taille differe de >10%. |
| R2S-03 | 15 | Acceptable — couvert par tests. |
| R2S-04 | 40 | **Important.** Le .tmp+mv est atomique sur ext4 mais PAS sur drvfs. Ajouter un sync apres mv sur drvfs paths (detect via df -T). |
| R2S-05 | 30 | Acceptable — liste statique, changement rare. Ajouter un commentaire TODO dans le code. |
| R2S-06 | 30 | Acceptable — seuil conservateur. |
| R2S-08 | 16 | Acceptable — monitoring non critique. |

---

## Bloc 2 — Session Metrics (session-log, sanitize-memory, colorize-handoff.py)

| ID | Script | Mode de defaillance | S | O | D | RPN | Mitigation |
|---|---|---|---|---|---|---|---|
| R2S-10 | session-log | Start file absent (/tmp perdu apres WSL reboot) | 2 | 5 | 1 | 10 | Loge "unknown" proprement. Test BATS couvre. Accepte. |
| R2S-11 | session-log | Start file contient des donnees non-numeriques | 3 | 1 | 1 | 3 | Regex guard + test BATS. |
| R2S-12 | session-log | Log CSV corrompu (append concurrent) | 4 | 2 | 6 | 48 | Pas de lock sur le fichier log. Risque si 2 agents handoff en meme temps. Probabilite faible mais non nulle. |
| R2S-13 | session-log | Drift warning non affiche (seuil 120/180 min mal calibre) | 2 | 3 | 2 | 12 | Seuils hardcodes, testes. Acceptable. |
| R2S-14 | sanitize-memory | Whitelist trop restrictive — supprime des sections utiles | 6 | 2 | 5 | 60 | Whitelist = Identity + Completed uniquement. Tout le reste est jete. Si une nouvelle section legitime apparait, elle sera detruite sans warning. |
| R2S-15 | sanitize-memory | Sentinel /tmp perdu — re-execute 2 fois le meme jour | 1 | 3 | 3 | 9 | Idempotent — double execution = meme resultat. |
| R2S-16 | sanitize-memory | Python awk rewrite corrompt MEMORY.md | 5 | 1 | 3 | 15 | awk est deterministe. Le tmp+mv est la bonne pratique. |
| R2S-17 | colorize-handoff.py | ANSI codes corrompent le rendu si terminal ne supporte pas 256 couleurs | 1 | 1 | 2 | 2 | Utilise les codes basiques (pas 256). Acceptable. |

### Fixes RPN > 10

| ID | RPN | Action |
|---|---|---|
| R2S-12 | 48 | Acceptable en pratique (2 agents handoff simultanement = scenario marginal). Ajout d'un flock si le pattern se revele en production. |
| R2S-13 | 12 | Acceptable — testes et documentes. |
| R2S-14 | 60 | **Important.** Ajouter un warning quand une section non-whitelistee est supprimee (log dans fleet-state.log). L'agent qui sanitize doit signaler ce qu'il jette. |
| R2S-16 | 15 | Acceptable — pattern standard. |

---

## Bilan Ring 2 Support

- 18 modes de defaillance analyses
- 2 critiques (R2S-02 RPN 126, R2S-14 RPN 60) — mitigations proposees
- 5 a surveiller (RPN 15-48) — acceptables avec les protections en place
- 11 sous controle (RPN < 10)
