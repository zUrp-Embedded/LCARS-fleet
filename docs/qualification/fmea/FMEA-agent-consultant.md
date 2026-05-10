# FMEA — Agent consultant (Tier 2, scope advisory)

**Date** : 2026-03-24
**Dernière révision** : 2026-03-24
**Statut** : initial — première passe
**Référencé par** : docs/qualification/fmea/, work/TODO/v6-qualification-plan.md
**Dérivé de** : fleet.yaml, roles/consultant.md, topologie.md

---

## Profil de risque

| Attribut | Valeur |
|---|---|
| Tier | 2 — worker projet |
| Scope | advisory (lecture code + directives, écriture ready-room/outbox/ uniquement) |
| Stateless | true (headless) |
| Interlocuteur | engineer (dispatch) ou direct (fleet-consultant.sh) |
| Privilèges | lecture large (code + directives), écriture très contrainte |

**Particularité** : consultant a une surface de lecture large (L1 + L4) mais une surface
d'écriture minimale (ready-room/outbox/ seulement). Son risque est le même que researcher
(informationnel) avec un accès codebase plus large.

---

## Table FMEA

| # | Composant | Mode de défaillance | Effet | S | O | D | RPN | Mitigation | Résidu |
|---|---|---|---|---|---|---|---|---|---|
| CT-01 | Conseil | Consultant donne un avis incorrect (analyse superficielle, biais du modèle) | Décision basée sur un mauvais conseil. Impact variable selon le sujet. | 6 | 4 | 5 | 120 | L'avis est consultatif — architect/engineer décident. Rapports dans outbox (user peut vérifier). | D=5 : un mauvais conseil bien formulé est convaincant. La mitigation est que le consultant ne décide pas. |
| CT-02 | Lecture | Consultant accède à des informations sensibles (credentials dans le code, secrets dans config) | Exposition d'information. Impact limité car stateless (pas de mémoire). | 5 | 3 | 7 | 105 | Pas de write sauf outbox. Stateless. Mais l'info peut se retrouver dans le rapport outbox. | D=7 : si le consultant cite un secret dans son rapport outbox, il est exposé. check-secrets.sh ne couvre pas les rapports outbox. Candidat : scan secrets sur outbox. |
| CT-03 | Scope | Consultant modifie du code ou des directives | Modification non autorisée. | 7 | 1 | 2 | 14 | Scope advisory = W ready-room/outbox/ uniquement. runtime-guard. Permissions Linux. | Très bien couvert. Triple protection. |
| CT-04 | IPC | Consultant utilise fleet IPC (interdit) | Message envoyé dans le spool, agent réveillé, tâche non autorisée lancée. | 6 | 2 | 3 | 36 | Directive "scope interdit : IPC fleet". Pas de fleet-send dans allowed-tools. | Bien couvert. L'agent n'a pas l'outil. |

---

## Synthèse

| Seuil | Count | Items |
|---|---|---|
| RPN >= 200 | 0 | |
| RPN 100-199 | 2 | CT-01 (120), CT-02 (105) |
| RPN < 100 | 2 | CT-04, CT-03 |

**Actions prioritaires** :
1. CT-02 (RPN 105) : scan secrets sur les fichiers déposés dans outbox
