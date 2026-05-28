# Fleet.Credentials

**Date** : 2026-05-28
**Dernière révision** : 2026-05-28 (rework post-audit L1)
**Statut** : actif — aligné ADR-F PROMOTED 2026-05-26
**DERIVED FROM** : `01_architecture/adr-f-credentials-anthropic-natif.md` + `04_design-notes/ring0/fleet_credentials.md`

Gates métier OAuth pour les pods LCARS v2. Le modèle d'auth est **claudeDir natif Anthropic** (`~/.claude/.credentials.json`) — LCARS ne gère ni le storage ni le refresh : juste **2 gates** (scope + plan) qui lisent le fichier directement.

## Modèle

Les pods s'authentifient via le claudeDir natif Anthropic, **partagé per-humain** entre les pods d'un même UID Linux (compose ADR-E : N humains = N users Linux dans 1 conteneur = N claudeDirs distincts). Le refresh OAuth cross-process est **100% délégué au binaire `claude`** via lockfile POSIX (`proper-lockfile`).

**Pas d'écriture LCARS *au runtime des pods* dans `.credentials.json`** — l'onboarding (par starfleet hors-bwrap, cf. §Onboarding) est la seule voie d'écriture. Pas de coffre LCARS, pas d'env vars `CLAUDE_CODE_OAUTH_*` injectées au pod, pas de scheduler refresh LCARS-side.

### Le `.credentials.json` natif Anthropic

Path **par défaut Linux** : `~/.claude/.credentials.json`, `chmod 0600` (imposé par le `plainTextStorage` Linux/WSL/Windows — seul backend utilisé par LCARS ; macOS utiliserait Keychain mais LCARS = Linux server-side). Override possible via env `CLAUDE_CONFIG_DIR` (non utilisé par LCARS).

Deux slots cohabitent dans le même fichier :

```json
{
  "claudeAiOauth": {
    "accessToken": "...",
    "refreshToken": "...",
    "expiresAt": <ms_epoch>,
    "scopes": ["user:profile", "user:inference", "user:sessions:claude_code",
               "user:mcp_servers", "user:file_upload"],
    "subscriptionType": "max" | "pro" | "team" | "enterprise" | null,
    "rateLimitTier": "..." | null
  },
  "mcpOAuth": {
    "<serverKey>": {
      "serverName", "serverUrl",
      "accessToken", "refreshToken?", "expiresAt", "scope?",
      "clientId?", "clientSecret?", "discoveryState?", "stepUpScope?"
    }
  }
}
```

- `claudeAiOauth` — subscription Anthropic principale (`claude /login`), gérée par `utils/auth.ts` du binaire claude.
- `mcpOAuth[serverKey]` — OAuth per-MCP-server (si MCP server requiert OAuth), géré par `services/mcp/auth.ts`. **Système distinct**, LCARS n'y touche pas. Share-claudeDir partage les deux slots implicitement. Schéma complet : reverse `#0_ref_mcp-oauth.md` §1.

## Modules LCARS-side (les seules choses qu'on code)

- `Fleet.Credentials.ScopeValidator` — gate **scope-coverage** : vérifie `oauth_scopes ⊇ scopes_requis_role` en lisant `claudeAiOauth.scopes` depuis `.credentials.json`. Profils :
  - `default` : requiert `user:inference` + `user:sessions:claude_code` (Remote Control)
  - `bridge_enabled` : profil bridge — scopes exacts dérivés au câblage
  - `mcp_oauth` : ajoute `user:mcp_servers` (pour les MCP-OAuth servers)
- `Fleet.Credentials.PlanValidator` — gate **plan Pro/Max/Team/Enterprise** (F-AC-VALIDATE) : lit `claudeAiOauth.subscriptionType` directement depuis le fichier. Pas d'appel réseau, pas de SDK.

## Distribution — `share-claudeDir` per-humain (ADR-F décidé 2026-05-26)

Tous les pods d'un humain bindent **son** claudeDir writable (`/home/<humain>/.claude/`). Frontière de partage = l'humain (UID/compte). **Isolation cross-humain** = UID Linux distinct + bwrap mount NS (cf. ADR-E §Isolation), pas le `chmod 0600` seul.

Le bind du claudeDir dans le pod est défini par `04_design-notes/ring0/bwrap_launch.md` (DN canonique ; le script `bin/bwrap_launch.sh` du runtime en est l'implémentation). Phase BIND de `fleet_project_bootstrap` configure les mounts. **Pas de copie** des creds entre pods (`copy-direct` rejeté par ADR-F).

PoC dé-risque (2026-05-26) : 5 pods bwrap concurrents + 1 warmup séquentiel ; claudeDir partagé intact, `projects/` sans collision, 0 lock résiduel. **Le PoC valide la concurrence claudeDir/`projects/`, PAS la safety du clobber `.credentials.json` sous refresh concurrent** (gate refresh >20min hors-scope par design ; cf. §Caveats).

### Caveats acceptés (cf. ADR-F + reverse)

- **Clobber `.credentials.json` sous refresh concurrent** : *présumé* safe (atomicité Anthropic `rename(2)` à confirmer au build — voir GAP G-3) ; gate refresh >20min hors-scope du PoC.
- **Fenêtre stale cache cross-process** (reverse §F6, Linux) : un pod qui voit son token comme frais ne re-lit pas le disque même si un autre pod a refresh ; converge sur le 1er 401 via `handleOAuth401Error`. Distinct du clobber, accepté par design.
- **Dead-token backoff partagé** (reverse §9, `initReplBridge.ts:177-240`) : état persistant dans **`~/.claude.json`** (NB : *pas* `.credentials.json`) — champs `bridgeOauthDeadExpiresAt` + `bridgeOauthDeadFailCount` (cap à 3), content-addressed par `expiresAt`. Si un pod hit "refresh-token mort" 3×, **tous les pods de l'humain** héritent du backoff. Recovery via `claude /login` interactif par l'humain : un nouveau `/login` produit un nouvel `expiresAt`, la clé content-addressée ne match plus → backoff reset implicitement (le `/logout` interdit par §Invariants n'est PAS requis).
- **Lockfile retry-exhausted** (reverse §F2, événement `tengu_oauth_token_refresh_lock_retry_limit_reached`) : sous N pods simultanés au même `expiresAt − 5min`, les 5 retries × 1-2s peuvent s'épuiser → `checkAndRefreshOAuthTokenIfNeeded` retourne `false` silencieusement → appel API part avec le token courant → 401 → recovery réactif via `handleOAuth401Error` côté binaire claude. Convergence assurée mais à monitorer (event à instrumenter au build).

## Onboarding

starfleet (sysadmin root-trusted, hors-bwrap per D-01) **est la seule voie d'écriture** dans `.credentials.json` — il pose les creds dans le claudeDir de l'humain à l'onboarding (compose ADR-E §Onboarding). DN onboarding/catalogue détaillée = backlog post-ADR-F.

## Précédence d'auth Anthropic (ordre officiel)

Anthropic résout les credentials dans cet ordre (rang 1 = **plus prioritaire**, préempte les rangs suivants) :

| Rang | Source | LCARS |
|---|---|---|
| 1 | Cloud provider (`CLAUDE_CODE_USE_BEDROCK`/`VERTEX`/`FOUNDRY`) | env filtrée |
| 2 | `ANTHROPIC_AUTH_TOKEN` | env filtrée |
| 3 | `ANTHROPIC_API_KEY` | env filtrée |
| 4 | `apiKeyHelper` script | settings.json contrôlé (non-configuré) |
| 5 | `CLAUDE_CODE_OAUTH_TOKEN` (long-lived setup-token) | env filtrée + jamais généré |
| **6** | **Subscription OAuth `/login`** | **← rang utilisé par LCARS** |

⚠ Précédence **descendante** : un rang supérieur **préempte** les rangs en-dessous. Si setup-token (rang 5) était présent, il masquerait la subscription (rang 6). LCARS l'empêche en **ne générant pas de setup-token** ET en **filtrant les env vars rangs 1-5** au lancement du pod.

Filtrage LCARS-side : le launcher du pod (cf. `ring0/claude_launch.md` + composants Elixir à dériver) retire `ANTHROPIC_API_KEY` / `ANTHROPIC_AUTH_TOKEN` / `CLAUDE_CODE_OAUTH_TOKEN` / `CLAUDE_CODE_USE_*` de l'env injecté ; `settings.json` du pod ne configure pas `apiKeyHelper`. Le `.credentials.json` natif fournit la subscription OAuth (rang 6).

NB : le reverse §26 (`utils/auth.ts:153-206`, `getAuthTokenSource()`) documente deux slots FD (`CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR`, `CCR_OAUTH_TOKEN_FILE` disk fallback) résolus autour des rangs `apiKeyHelper` / `CLAUDE_CODE_OAUTH_TOKEN`. LCARS n'injecte ni FD ni fichier de fallback — slots inopérants. (`ANTHROPIC_API_KEY` rang 3 est résolu par fonction sœur `getAnthropicApiKeyWithSource()`.)

## Invariants

- **JAMAIS** `ANTHROPIC_API_KEY` (rang 3, filtré).
- **JAMAIS** `ANTHROPIC_AUTH_TOKEN` (rang 2, filtré).
- **JAMAIS** `--bare` (mode API-key only, skip subscription OAuth entièrement — gate avant la précédence).
- **JAMAIS** `claude setup-token` : scope `user:inference` UNIQUEMENT → (a) incompatible MCP-OAuth (`user:mcp_servers` absent), (b) **incompatible Remote Control** (`user:sessions:claude_code` absent) → **rompt directement ADR-G** ; user-reject explicite 2026-05-09.
- **JAMAIS** `/logout` : `secureStorage.delete()` supprime `.credentials.json` **intégralement** (slot `claudeAiOauth` + tous les slots `mcpOAuth[*]`) → wipe **tous** les pods de l'humain + tous les MCP-OAuth servers de l'humain.
- Refresh = **délégué au binaire claude** (lockfile natif, refresh à `expiresAt − 5min`, 5 retries 1-2s backoff).
- Atomicité = lockfile POSIX natif Anthropic (cf. §Caveats acceptés).

## Cohérence ADR-G (post-15/06/2026)

Le pivot facturation Anthropic (annoncé 14/05/2026, effectif 15/06/2026, confirmé par la doc officielle) sépare :

- **Interactif terminal `claude` REPL** = subscription = **utilisé par LCARS**.
- **Programmatique `claude -p` / SDK / stream-json** = pool métré séparé = **interdit pour LCARS**.

LCARS lance les pods en **Mode A interactif** per ADR-G (REPL `claude` interactif sous tmux ; activation Remote Control par `remoteControlAtStartup:true` dans `settings.json` du pod, ou slash `/remote-control [name]` dans le REPL — incantation exacte définie par `04_design-notes/ring0/claude_launch.md`). **Mode B** (sous-commande `claude remote-control` qui spawne des enfants `claude --print`) = headless = **explicitement écarté par ADR-G L29**.

## Articulation

| Doc | Relation |
|---|---|
| `01_architecture/adr-f-credentials-anthropic-natif.md` | ADR canonique PROMOTED 2026-05-26 |
| `01_architecture/adr-e-single-user-runtime.md` | N humains = N users Linux dans 1 conteneur ; N claudeDirs |
| `01_architecture/adr-g-launch-subscription.md` | Mode A interactif tmux (subscription), pas `-p` (métré) |
| `04_design-notes/ring0/fleet_credentials.md` | modèle court (claudeDir natif + 2 gates) |
| `04_design-notes/ring0/bwrap_launch.md` | bind du claudeDir humain RW |
| `04_design-notes/ring0/claude_launch.md` | incantation exacte du REPL Mode A |
| `04_design-notes/ring1/fleet_project_bootstrap.md` | Phase 4 BIND claudeDir |

## Sources externes

- Reverse `inbox/src/#0_audit-reverse/#0_ref_oauth-token-lifecycle.md` (snapshot 2026-04-12, addendum 2026-05-01 — basé sur Claude Code v2.1.88) — OAuth claude.ai principal : `utils/auth.ts`, lockfile, refresh, anti-storm. Mécanique stable confirmée par la doc officielle.
- Reverse `inbox/src/#0_audit-reverse/#0_ref_mcp-oauth.md` (snapshot 2026-05-01) — OAuth MCP per-server : slot distinct `mcpOAuth[serverKey]`, lockfile per-server, XAA/CIMD (enterprise, non-applicable starfleet personnel).
- Doc officielle Anthropic à jour : `https://code.claude.com/docs/en/authentication` (la plus récente, priorité 1 en cas de divergence reverse/canon).
