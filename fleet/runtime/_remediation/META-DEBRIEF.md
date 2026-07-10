# META-DÉBRIEF — chaque dérive évitée → règle datée

**Date** : 2026-07-10
**Dernière révision** : 2026-07-11
**Statut** : actif (append-only, garde le protocole vivant)
**Référencé par** : `PLAYBOOK.md`

> Seed 3 de l'amorce : une règle que J'ÉCRIS depuis la friction se déclenche au point de décision ; une
> règle reçue non. Ici chaque quasi-raccourci, correction, ou rattrapage devient une règle datée, à moi.

## Règles amorcées (portées depuis cette session — déjà éprouvées, pas reçues)

- **R-01 (2026-07-10)** — *Vérifier le vérificateur.* Le rapport ment aussi sur OÙ va le fix. Preuve vécue :
  amnésie WAL — l'agent situait le fix dans `read_wal`, mais `decode/1` avalait déjà l'erreur Jason en `%{}`
  → la branche proposée aurait été **du code mort**. Lire le vrai chemin de données, pas la ligne pointée.
- **R-02 (2026-07-10)** — *Un candidat « mort » est souvent porteur.* `:jose` (0 usage lib) = transitif
  obligatoire d'ex_mcp ; `finch` = pool de Req. Grep-négatif ≠ mort. Vérifier la voie dynamique (config, capture, MFA, transitif).
- **R-03 (2026-07-10)** — *Le préfetch OK vs le cache KO.* Réutiliser UNE lecture dans une fenêtre
  verrouillée = bon dédup. Un cache-à-travers-le-temps avec TTL = soft-default déguisé (staleness = mensonge). Refuser.
- **R-04 (2026-07-10)** — *L'outbox est un 2e SSOT.* Ne pas prescrire d'outbox pour un event lifecycle dont
  la forge possède déjà le fait ; identifier la preuve forge manquante, pas ajouter un store durable concurrent.
- **R-05 (2026-07-10)** — *Ne pas inférer la couverture d'un grep.* Un fichier n'est couvert que quand son
  état de vérif change avec citations. (Discipline ledger de Codex, adoptée.)

## Débriefs de session (depuis la friction réelle)

- **R-06 (2026-07-10)** — *Vérifier DEUX choses, pas une : (1) la brèche est-elle réelle ? (2) le FIX est-il
  mécanique ou un choix de design ?* En re-vérifiant les hollow-gates « clairs » de la phase 1, deux ont
  révélé un **fork doctrine dans leur fix** : F-C167 (le gate `05_data-canon` est vide-mais-l'invariant est
  en fait VIOLÉ dans 5 tests → re-câbler tout / supprimer le scaffold obsolète / marquer non-câblé = choix),
  F-C165 (la bonne liste de rôles = ceux qui ont `needs_role_token`, pas un swap vulcan→starfleet). J'ai
  failli les fixer unilatéralement. **Règle : un gate CI / une liste déployée dont le fix a plusieurs formes
  valides = doctrine, je flag.** Corollaire : « PERCE » (brèche réelle) ≠ « fix mécanique ».
- **R-07 (2026-07-10)** — *Le hollow-green cache parfois une VRAIE violation.* F-C167 : le gate ne checkait
  rien ET l'invariant qu'il prétend tenir (0 ref `05_data-canon` en test) est **violé** (5 fichiers). Le
  faux-vert masquait le vrai rouge. Toujours vérifier ce que le gate DEVRAIT trouver s'il tournait.

- **R-08 (2026-07-10)** — *Pour un finding « config malformée », le test d'atteignabilité est : un CONFIG RÉEL
  (runtime.exs / config.exs / test.exs) pose-t-il une valeur malformée ?* Si la clé est **jamais posée**
  (lue avec un défaut hardcodé toujours utilisé), la brèche n'est atteignable que par une misconfig-future
  d'opérateur → c'est du **garde-contre-misconfig = DOCTRINE (D4 require-vs-soft)**, PAS un fix mécanique.
  Vécu : F-C099/104/117/082 (audit/interval/timeout/write_spacing) — clés absentes de tout config →
  reclassés DOCTRINE. Nuance retenue : un knob ACTIVEMENT configuré (F-C097 `:start_*`, posé en test.exs)
  avec un typo plausible + une doctrine codebase établie (EnvParse « load-bearing → raise ») justifie le fix.
  Corollaire de R-06 : « PERCE » (worker) ≠ « atteignable par un chemin réel aujourd'hui ».

- **R-09 (2026-07-10)** — *Vérifier que la CONSÉQUENCE se matérialise, pas juste le mécanisme.* Un finding
  peut décrire un vrai mécanisme (unlock jeté) mais une conséquence qui **ne survient pas**. F-C060 :
  « promote_pr jette l'unlock → issue reste lcars-in-flight → churn ». Réalité tracée : `seal_and_merge`
  **ferme l'issue** ; le poller ne dispatch que des issues **ouvertes** → jamais de re-dispatch → **pas de
  churn** ; et la Réconciliation réclame les locks orphelins (producteur killé) → le label est nettoyé.
  Résidu réel = label cosmétique sur issue fermée + log « released » imprécis (rare). Fix = harness
  disproportionné vs valeur → **downgrade, pas de gold-plating.** Corollaire de R-01 : tracer le chemin
  jusqu'au MAUVAIS RÉSULTAT, pas s'arrêter à la ligne fautive.

- **R-10 (2026-07-10)** — *Ajouter une nouvelle forme de retour `{:error, {:tag, …}}` = tracer TOUS ses
  callers avant de committer.* Un `case`/handler peut n'avoir AUCUN catch-all → la forme neuve tombe en
  CaseClauseError (500), pire que le bug d'origine. Vécu : F-C119 — `validate_issue_id` a renvoyé
  `{:invalid_issue_id, _}`, mais `Fleet.API.Rest.do_admin_spawn` matchait chaque refus explicitement (pas de
  `_ ->`) → crash. Le RED l'a attrapé (raison de plus de faire RED-first sur un test d'INTÉGRATION, pas juste
  unitaire). Corollaire de la classe intégrité : une nouvelle branche de retour n'est jamais purement locale.

- **R-11 (2026-07-11)** — *Une def publique insérée ENTRE des clauses de même nom/arité casse le groupe →
  `mix compile --warnings-as-errors` échoue.* Vécu : F-C037 (`result_deadline_fire/2`) et F-C119
  (`validate_issue_id/1`) posées au milieu d'un groupe `handle_event/4` resp. `parse_admin_spawn_dto/1`.
  Placer les seams @doc false HORS des groupes de clauses, et **lancer le gate `--warnings-as-errors` après
  tout ajout de fonction près d'un groupe** (le gate CI l'aurait bloqué — je l'ai attrapé à la vérif milestone).
- **R-12 (2026-07-11)** — *Un `capture_log` en test `async` capture TOUT le log global (bleed inter-tests).*
  Une assertion `refute log =~ <chaîne>` doit keyer sur un token UNIQUE au module (préfixe `ModuleName:`), pas
  une chaîne partagée. Vécu : `arch_escalation_test refute =~ "NOT added"` flaky car `IncidentRegistry.Escalation`
  émet aussi « NOT added » et bave sous charge concurrente. Fix : token arch-unique `ArchEscalation:`. Corollaire :
  faire tourner le gate `mix test` COMPLET (pas app-par-app) révèle les flaky de bleed que les runs isolés cachent.

- **R-13 (2026-07-11)** — *À la frontière de l'autonome, la prep FACTUELLE bornée avance le chantier ; la
  RE-ANALYSE spéculative d'un travail décision-driven que le user possède = churn déguisé en productivité.*
  Vécu : mécanique 100% close → j'ai fait un preview D7 (Credo/Sobelow/F-C167 = data TOOL factuelle, utile
  quel que soit le choix user) MAIS j'ai STOPPÉ avant de « préviewer » D1-D6 (best-effort-vs-load-bearing,
  garder-vs-resserrer, direction-SSOT = JUGEMENT, pas data). Re-analyser ça aurait été décider à la place du
  user + du churn pour ne pas idler. Corollaire du débrief best-effort/flemme : **le churn est l'AUTRE face de
  la paresse** (s'acharner sur du non-sujet pour éviter le vrai). La décision user EST le gate — on s'arrête là.
