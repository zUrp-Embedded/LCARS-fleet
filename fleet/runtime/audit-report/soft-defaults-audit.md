# Audit — « repli mou silencieux » (soft defaults / fail-open sur le chemin malheureux)

**Date** : 2026-07-09
**Statut** : recon CLOSE (6 chercheurs adversariaux, 14 apps, croisés/vérifiés) — triage user en attente
**Méthode** : fan-out 6 agents (seams sécu ×3 sous-agents, config, avalage-erreur, vide→permissif, rail/décision, fondation/bord), chaque candidat lu+vérifié, classé Tier-1/2/faux-positif.

## Mission (reframe user)

Un repli = un **aveu** qu'à ce point la valeur peut être absente/invalide et qu'on n'a **aucune garantie**. Le canary (le `case par défaut`), c'est le symptôme ; la maladie, c'est le flux de données non-garanti en **amont** qui laisse le vide arriver jusqu'à l'usage.
- **Symptôme (à éviter)** : repli → `raise`. Le vide arrive toujours, on le rejette tard.
- **Guérison (la cible)** : rendre le vide **INREPRÉSENTABLE en amont** (smart-ctor, champ requis au schéma, parse-au-bord, validation-au-boot, type non-vide-par-construction) → le `case par défaut` devient **mort → supprimé.**

## Verdict d'ensemble

Le pattern est **largement éradiqué** — des dizaines de faux-positifs vérifiés qui sont *le bon* pattern de référence (creds gate fail-closed, HMAC clé-vide→401, `EnvParse` port/path→raise, `read_agent_draft` no-fallback, verdict jamais-approve-par-omission, containment défaut `bwrap`, `AggregateDispatcher` sentinelle `>0`). La campagne finition a mordu. Restent 7 vrais replis Tier-1 (dont 3 LIVE) + une poignée de Tier-2.

## TIER-1 — le repli + le verrou amont

| # | Repli (fichier:ligne) | Déclencheur → garantie relâchée | Live | Verrou amont (tuer le cas) |
|---|---|---|---|---|
| ① | `pilot/poller/lease.ex:237` catch-all `_ -> {false,[]}` | transient `get_route` `{:error}` sur issue engagée → bail repo LIBÉRÉ → double-dispatch | **OUI** | Panne externe → **fail-CLOSED symétrique** : retirer le `_ ->`, variant erreur distinct, sur erreur → `engaged=true` (comme le frère l.230-231 dont le commentaire décrit le danger). Oversight. |
| ② | `cap_profile.ex:426` `brief_kind` défaut `"worker"` | `brief_kind` absent → brief EXÉCUTABLE ; un juge sans `brief_kind:judge` exécuterait le contenu attaquant | Latent | **`brief_kind` requis au schéma** `cap-profile-v2.5.json` (≥ pour rôle-juge) → rejet au load → défaut mort. (Le moduledoc dit « judge-ness = sécu, jamais inférée » — le code doit suivre.) |
| ③ | `pilot/forge_client.ex:911` `as_role` + `credentials/role_token.ex` | role-token nil → sceau gatekeeper sous **token SYSTÈME** | OUI | Frère fail-closed **déjà écrit** : `mcp/delegation.ex:71` → `{:error,:role_token_unavailable}`. Aligner, ou smart-ctor `RoleIdentity`. **R3/drdree = doctrine.** |
| ④ | `workflow/gates.ex:63` hard-gate `rules:[]` → `Enum.all?([])==true`→`:pass` | hard-gate à rules vides n'applique rien (schéma-valide, non compensé) | OUI si mal-authored | **`minItems:1`** au schéma + parse `%HardGate{rules:[_|_]}` non-vide-par-construction → vacuité inatteignable. |
| ⑤ | `spawner/pod/launch_spec.ex:266` mount `mode` non borné | `mode` nil/typo → brut dans `LCARS_POD_MOUNTS` (RW hors-sandbox ?) | Latent | Parser `mode` en enum fermé `{ro,rw}` **au load** (comme `permission_mode/1` l.168). |
| ⑥ | `mcp/server.ex:44` `:boot_environment` absent → `:host` | défaut permissif sur invariant confinement | Latent | **Inverser fail-closed** (absence→refuse) ou config requise. |
| ⑦ | `pilot/forge_client.ex:634` `comment_signed?` bot_login non résolu → croit tous les auteurs | dedup gameable → sous-compte budget anti-runaway | Étroit | Aligner sur frères l.749/775 (refus `{:error}`). |

## TIER-2 — dégradation muette (à signaler)

**Vivants :**
- `spawner/permanent_boot.ex:289` — seed corrompu → `rescue _ -> nil` **ZÉRO log** → permanent reboote from-scratch, contexte perdu. Le seul *totalement* silencieux.
- `event_router/webhooks_gitea.ex:67` — `Bus.emit` `{:error}` tuple jeté par `_ =` → **ACK 200 sur webhook droppé** → Gitea ne retente pas (contredit l'invariant du module).
- `pilot/step_dispatcher/spawn.ex:225` `safe_wake rescue _ -> :ok` — wake qui raise → tally `dispatched+1/errors 0` faux.
- `mcp/supervisor.ex:108` `rescue _ -> 0` — la sonde anti-vert-creux rend `:operational` quand elle crashe.
- `pilot/incident_registry.ex` (sync_forge/read_wal/load_forge `_ -> %{}`) — amnésie → récurrence relue « 1re fois ».
- `observation` read-model aveugle/mort → sert du vide, **LED verte** (câblée sur `/api/pods`, pas la projection).

**Dormants (aucun producteur / prod-câblé — verrous « wire-time ») :**
- `starfleet/coord_backend.ex:52` `NotWiredYet → :ok` ; `shutdown.ex` `NoOpDispatcher` ; `coord` `:no_policy_match` droppé (`drift_monitor:111`, `cat5_escalator:89`) ; `drift_monitor:132` `drift_count→0`. Prod câble `Fleet.Coord`/`AggregateDispatcher` (`runtime.exs:233/242`) ; producteurs `audit.verdict`/Cat-5/`pod.drift` pas implémentés.

## Faux-positifs (le CORRECT — référence)

`read_agent_draft` (no-fallback), creds `gate`/`scope_validator`/`plan_validator` (refus typé total), `EnvParse` (raise), `BindAddress` (loopback+raise), `Catalog.load!` (raise-boot), HMAC (401 clé-vide), coord `policies.ex` (raise-boot), `verdict.ex` (approve only-on-`"continue"`), `apply_verdict` (unknown→freeze_to_arch), containment (`bwrap` défaut, host only-on-`"none"`), `AggregateDispatcher` (sentinelle `>0`), `MCPMonitor`/`mcp_monitor` (crashed-on-uncertainty), task_queue `get_for_pod → {:error,:no_work_item}`.

## Triage recommandé (ordre)

1. **① lease.ex:237** — seul LIVE + intégrité + fix propre (symétrie fail-closed). D'abord.
2. **② cap_profile brief_kind + ④ gates rules:[]** — verrous de SCHÉMA (le plus « guérison » : cas mort au load). R0/R2, mien.
3. **⑤ mount mode + ⑥ mcp boot_environment** — confinement, défense-en-profondeur.
4. **③ role_token→système** — R3/drdree, DOCTRINE (user tranche).
5. **⑦ bot_login** — étroit, aligner sur frères.
6. Tier-2 vivants (permanent_boot silent, webhooks 200, safe_wake, mcp hollow-green) ; Tier-2 dormants = wire-time.

Chaque case : TDD (RED prouve le repli → verrou amont → GREEN → `case` supprimé), gate, commit/unité.

---

## Remédiation (en série, décision user 2026-07-09 : les 7 Tier-1 + ③ par smart-ctor RoleIdentity)

- [x] **① lease.ex:237** — `0e8b4b27e` — get_route erreur → fail-CLOSED (bail tenu). TDD RED→GREEN, pilot 347/0.
- [x] **② cap_profile brief_kind** — `802c14643` — REQUIS au schéma (défaut worker supprimé). TDD, cap_profile 112/0 + pilot 347/0 + spawner 211/0. Co-update 7 fixtures.
- [x] **④ gates.ex:63** — `cdffce346` — schéma `if type==hard then minItems 1` + eval garde `rules != []`. TDD ×2, workflow 139/0, pilot 347/0.
- [x] **⑤ launch_spec mount mode** — `bcec15d47` — borne `{ro,rw}` au eval (schéma déjà enum au load). TDD, spawner 212/0.
- [x] **⑥ mcp boot_environment** — d8ae8f1a7 — défaut fail-closed :pod + host déclaré positivement. TDD, mcp 52/0.
- [ ] **③ role_token→système** — smart-ctor `RoleIdentity` (pilot+mcp).
- [x] **⑦ forge_client bot_login** — e7fbd2797 — dedup bot non-résolu → trust personne (fail-closed). TDD, pilot 348/0.
