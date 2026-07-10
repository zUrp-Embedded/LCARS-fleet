# JOURNAL — remédiation SSOT/irrepr (chronologique)

**Date** : 2026-07-10
**Dernière révision** : 2026-07-10
**Statut** : actif
**Référencé par** : `CARNET-DE-BORD.md`

## 2026-07-10

### Montage (phase 0 amorcée)
- Worktree `remediation-ssot` créé off `main` (1f53f030b) dans `/home/lordzurp/wt-remediation`. Commit-local.
- Source Codex copiée dans `source-codex/` (findings-campaign + frontiers + final-report + coverage) — self-contained pour la reprise.
- Ledger `LEDGER.csv` généré : **167 findings** (36 high / 79 medium / 37 low / 15 hygiene), tous `PENDING`.
- Docs de campagne posés : `PLAYBOOK` (mon protocole), `CARNET-DE-BORD` (ancre reprise), `PLAN` (canard), ce journal, `META-DEBRIEF`.
- Lecture de l'`amorce` (beyond_#5.1) : construire mon protocole depuis les graines, pas dérouler une spec. Fait.
- **Aucun code touché** (règle cardinale : rien avant vérif percé).

### Phase 0 — verify-sweep LANCÉ
- Crons armés : watchdog `a73c2099` (`3-59/10 * * * *`), relevé `b1dc7bc3` (`47 * * * *`). Session-only → à supprimer en fin.
- **8 workers Explore** lancés en fan-out (F-C001→167, ~21 chacun) : vérif adversariale contre le code réel du worktree, verdict PERCE/THEORIQUE/DEJA-FIXE/DOCTRINE + citations + vrai chemin de données.
- Attente : consolidation des verdicts dans `LEDGER.csv` dès retour des workers, puis spot-vérif moi-même des PERCE à fort enjeu, puis regroupement B5 en familles de constructeurs.

### Phase 0 CLOSE — 167/167 vérifiés
- 8 workers rentrés. Verdicts capturés par lot dans `verdicts/lot-*.md` (durable), consolidés dans `LEDGER.csv` + `CONSOLIDATION.md`.
- **Distribution** : 71 DOCTRINE (42,5 %) · 49 PERCE-code · 25 PERCE-doc · 21 THEORIQUE · 1 DEJA-FIXE.
- **Gain règle cardinale** : 21 THEORIQUE dissous (schéma verrouille déjà à l'entrée / producteur passe valide / prose non-assemblée) → 21 non-brèches non-fixées. Plusieurs localisations corrigées (vrai verrou un niveau au-dessus).
- **PERCE code → 6 familles** : F gates(5) · C ingress-parse(10) · B config-parse(6) · D identité(4) · E schéma(2) · A fail-closed(22). Le « constructeur » (B/C/D/E ~22) = ~5-6 smart-ctors ; A ~22 edits fail-closed (pattern intégrité prouvé).
- **DOCTRINE → 7 clusters** (D1 fiabilité-events · D2 stubs-MVP · D3 canon-legacy · D4 config-boot · D5 tolérances · D6 SSOT-cross-surface · D7 outillage) — checkpoint user.
- **Aucun code touché.** → attente GO phase 1 + steer triage doctrine.

### Phase 1 — hollow-gates (en cours)
- **F-C166 FIXÉ** (`2d6cee826`) : gate-r0.1-bwrap sentinelle host déterministe → fin du faux-vert ISO. bash -n OK (gate complet non-runnable ici : bwrap/vendor absents).
- **F-C167 → doctrine-tail (flag user, D7)** : re-vérif → `05_data-canon` encore référencé dans 5 tests → le gate câblé ÉCHOUERAIT. Fix = re-câbler / supprimer le scaffold / marquer = choix de design sur un gate CI. Non touché.
- **F-C165 → doctrine-tail (flag user, D6)** : la bonne liste = rôles `needs_role_token`, pas swap vulcan→starfleet. Non touché.
- **F-C164** : à re-vérifier (install.sh copie-list) — probablement propre. **F-C160** : couverture test brief-gate (Elixir) — avec les tests.
- Règles R-06/R-07 ajoutées au méta-débrief (re-vérif = 2 mis-fixes évités ; hollow-green masque un vrai rouge).

### Phase 1 — F-C164 reclassé FAUX (verify-the-verifier)
- **F-C164 → THEORIQUE** : `bin/claude_launch.identity` = constante vendor COMMITTÉE (NAME/EMAIL, trackée), pas un secret à générer. `install.sh` clone tout le repo → présente ; `publish-to-github.sh` la résout relativement (`etc/../bin`). Citation Codex `install.sh:50 copie sélective` factuellement fausse (install.sh ne copie rien, il clone+délègue). Aucune brèche → PAS de fix.
- **Bilan phase 1** : 5 « hollow-gates clairs » → 1 fix propre (F-C166), 2 doctrine-tails (F-C167 D7, F-C165 D6), 1 FAUX (F-C164), 1 restant (F-C160 couverture test brief-gate). La règle cardinale a évité 1 mis-fix + 2 fix-mal-formés sur 4.
- Distribution ledger : PERCE 48, THEORIQUE 22 (F-C164 migré).

### Phase 1 CLOSE
- **F-C160 FIXÉ** (couverture brief-gate, 12 tests/0). brief_kind:judge survit à la normalisation (bonus : confirme F-C109 = MAP-level seulement).
- **Bilan phase 1 (5 findings)** : 2 FIXÉS (F-C166 sentinelle bwrap, F-C160 conformance brief-gate) · 2 DOCTRINE-TAIL (F-C167→D7, F-C165→D6) · 1 FAUX (F-C164). La règle cardinale a évité 3 fixes erronés sur 5 (2 mal-formés + 1 non-brèche).
- → PHASE 2 : constructeurs de frontière (B/C/D/E). Je commence par re-vérifier une famille + concevoir le smart-ctor.
