defmodule Fleet.Spawner.Pod.LaunchEnv do
  @moduledoc """
  CONSTRUCTION de l'environnement de lancement + résolution/validation des CREDENTIALS du pod —
  extraite de `Fleet.Spawner.Pod`.

  Un seul rôle : à partir du `state` (env de base, cap_profile, opts), du `role`, du `containment` et
  du chemin du launcher vendor, produire l'env COMPLET passé au backend de lancement — auth `bind`
  posée, identité git de l'humain résolue, porte credentials (scope/plan) franchie — ou un
  `{:error, reason}` DÉJÀ taggé. `build/4` ne touche ni Port, ni timer, ni state machine : il rend une
  valeur, le `Pod` (état `:launching`) la branche sur `do_launch_backend` ou `transition_failed`.

  ## MÉCANIQUE CREDENTIAL — sanctuaire déplacé tel quel

  Les helpers creds (`claude_dir*`, `passwd_home`, `claude_bin_in_home`, `maybe_put_*`) et le bloc
  encadré « ON N'Y TOUCHE PAS » qui les chapeaute ont été déplacés VERBATIM depuis `Pod` : per-humain
  OUI, partagé-writable OUI, broker NON (cf. le bloc encadré ci-dessous). L'auth reste mono-valeur
  `LCARS_AUTH_MODE=bind` — pas de switch, pas de variante.

  ## Contrat (appelé par `Pod`)

  - `build(state, role, containment, claude_launch_path)` — appelée par l'état `:launching` ; rend
    `{:ok, env}` (auth `bind` posée, identité git de l'humain, porte scope/plan franchie) ou
    `{:error, reason}` DÉJÀ taggé `:launch_env_unresolved` (raise de résolution humain/passwd/vendor-bin),
    `:credentials_invalid` (porte scope/plan) ou `:auth_token_required` (auth/identité git). Ordre
    auth → git → gate préservé. L'état `:launching` la branche sur `do_launch_backend` / `transition_failed`.
  - `claude_dir/0` — claudeDir de l'humain runtime (override config `:claude_dir` sinon
    `~/.claude`) ; **publique** car aussi appelée par l'état `:injecting` (`Pod`) pour `CLAUDE_DIR` à l'injection.

  Dépend de `Pod.LaunchSpec` (builders d'env), `Pod.McpProvision` (`mcp_channel_env`), `Pod.Paths`
  (`runtime_home`), `Fleet.Credentials.*` (Human/ForgeIdentity/Gate, pleine qualif) et
  `Fleet.Spawner.PodTmux` (`sock_base`, pleine qualif). Aucune dépendance vers `Fleet.Spawner.Pod`
  (pas de cycle).
  """

  alias Fleet.Spawner.Pod.LaunchSpec
  alias Fleet.Spawner.Pod.McpProvision
  alias Fleet.Spawner.Pod.Paths

  @doc """
  Construit l'env COMPLET de lancement du pod + résout/valide les credentials.

  Rend `{:ok, env}` (auth `bind` posée, identité git de l'humain, porte scope/plan franchie) ou
  `{:error, reason}` taggé (`:launch_env_unresolved` | `:credentials_invalid` | `:auth_token_required`),
  branché par l'état `:launching` sur `do_launch_backend` / `transition_failed`. `role`/`containment`/
  `claude_launch_path` sont résolus côté `Pod` (état `:launching`) et passés ici : `role` ==
  `cap_profile_name(state.cap_profile)` (même valeur, calculée pareil) → on évite la dépendance au
  private de `Pod`.
  """
  def build(state, role, containment, claude_launch_path) do
    # La résolution humain + le pipeline env peuvent RAISE (runtime_user /
    # claude_dir_from_passwd / maybe_put_vendor_bin = fail-loud sur host sans claude
    # per-user ou home irrésoluble). Un raise non rattrapé ICI crasherait le process pod (gen_statem) SANS
    # transition_failed → task orpheline :pending + state.json à la phase périmée. On
    # rabat tout raise de construction-env sur transition_failed (même cleanup que les
    # autres échecs launch : clear_pod_task + phase=failed).
    launch_env =
      try do
        human = Keyword.get(state.opts, :human) || runtime_user()
        # Creds résolus UNE fois (fail-loud si passwd humain introuvable) : sert au HOME host
        # (`launch_home`, parent du claude_dir) ET à CLAUDE_DIR. Valeur déterministe (config + passwd).
        claude_dir = claude_dir_for(human)

        env =
          state.env_vars
          |> Map.merge(LaunchSpec.skills_plugins_env(state.cap_profile))
          |> Map.merge(
            McpProvision.mcp_channel_env(
              state.pod_id,
              role
            )
          )
          # HOME — dépend du containment.
          #   bwrap (défaut) : HOME=pod_dir (cohérent ; bwrap fait `--setenv HOME` de toute façon,
          #     cette valeur est ignorée sous le sandbox).
          #   none (host)    : HOME = home RÉEL de l'humain → claude lit son `~/.claude` natif. C'est l'auth
          #     `:bind` réalisée NATIVEMENT sur l'hôte (refresh OAuth, full scope, pas de falaise 8h — l'arch
          #     est un pod forever). host_launch.sh ne re-setenv PAS (pas de namespace) : ce HOME EST l'env réel.
          |> Map.put("HOME", LaunchSpec.launch_home(containment, state.pod_dir, claude_dir))
          # Chaîne de session : bwrap_launch les `--setenv` dans le pod,
          # claude_launch les lit `:?` strict (no-boot sinon).
          |> Map.put("LCARS_POD_SESSION_ID", state.session_id)
          |> Map.put("LCARS_POD_RESUME", if(state.resume, do: "1", else: "0"))
          # Mode permission : défaut `default` → claude_launch passe `--permission-mode default`
          # (allow/deny lists ENFORCED) au lieu de `--dangerously-skip-permissions` (héritage « agents dans la
          # nature » qui bypasse TOUT). Monde shapé (bwrap RO/RW + cap-profile) → le bypass est inutile, il ne
          # ferait que neutraliser nos listes. Override par cap-profile `spec.invocation.permission_mode`
          # (ex. "bypassPermissions" pour ré-ouvrir le yolo explicitement). NB : l'enforcement de l'écriture =
          # le MOUNT (RO/RW), pas la tool-list → les juges gardent Write/Edit (rapports), bornés par le mount.
          |> Map.put("LCARS_PERMISSION_MODE", LaunchSpec.permission_mode(state.cap_profile))
          # Nom RC Desktop : `<projet>_<role>` fourni par le dispatch (`opts[:rc_name]`) ; défaut = role
          # seul (pods permanents / sans projet). claude_launch le passe en
          # `--remote-control "<nom>"` EXACT (zéro suffixe auto → pas de « noms random qui s'empilent »).
          # Sessions RC per-user (l'humain ne voit QUE les siennes). Visibilité Desktop gatée côté
          # claude_launch.sh (lit `invocation.remote_control` du cap-profile). NB : la VALEUR est le nom
          # EXACT, pas un préfixe — le nom d'env legacy (`_NAME_PREFIX`) est conservé (moins de churn).
          |> Map.put("LCARS_POD_SESSION_NAME_PREFIX", Keyword.get(state.opts, :rc_name, role))
          # Base sock tmux : bwrap_launch crée la socket sous <base>/<pod_id>/, PodTmux (host) y tape.
          # MÊME valeur des deux côtés ⇒ le sock calculé coïncide. La valeur = PodTmux.sock_base (défaut
          # home-relatif `~/.lcars/run/tmux-sock` pour une fleet lancée par un humain ; jamais /run/lcars).
          |> Map.put("LCARS_TMUX_SOCK_BASE", Fleet.Spawner.PodTmux.sock_base())
          # Le pod est celui de l'HUMAIN : creds ET binaire vendor suivent /home/<human> (même règle que
          # pod_dir). Le binaire est résolu robustement ici (depuis ~/.local/bin, pas le pari `command -v`).
          # Le pod tourne SOUS l'UID de l'humain PAR CONSTRUCTION : le runtime tourne *as* l'humain
          # (chaque humain = SA fleet sous son user), le pod = Port BEAM hérite cet UID →
          # ownership/perms/isolation OS gratis, PAS de systemd-run --uid. (Seul starfleet a un user
          # dédié, hors-fleet.)
          |> Map.put("CLAUDE_DIR", claude_dir)
          |> maybe_put_vendor_bin(human)
          |> LaunchSpec.maybe_put_pod_cwd(state.opts, state.cap_profile, state.pod_dir)
          # Relocalise le home intra-pod (bwrap only) → bwrap masque le pod_dir réel.
          |> LaunchSpec.maybe_put_sandbox_home(state.cap_profile, state.pod_dir)
          # LCARS_POD_DIR (racine pod vue par l'agent, où vivent watch.sh/turn.flag) n'est PAS posée ici —
          # ce serait du dead code : bwrap_launch `--clearenv` la strippe, et host_launch l'`export`e
          # lui-même (= $POD_DIR). Le SP/watch.sh lisent `${LCARS_POD_DIR:-$HOME}` :
          # host → la var ; bwrap → fallback `$HOME` (= /home/.pod = racine pod).
          # Mounts CATALOGUE (cap-profile-driven) → bwrap_launch les bind. Vide / host_launch = inerte.
          # `system_mounts` préfixe le dir des launchers (install) → claude_launch.sh visible dans le sandbox.
          |> Map.put(
            "LCARS_POD_MOUNTS",
            LaunchSpec.pod_mounts_env(state.cap_profile, claude_launch_path)
          )

        {:ok, human, env}
      rescue
        e -> {:error, {:launch_env_unresolved, Exception.message(e)}}
      end

    # L'étape auth sort du pipe (pose LCARS_AUTH_MODE=bind, fail-loud sur erreur). La porte
    # credentials (scope/plan) suit, taguée {:credentials_invalid, _} pour un refus distinct de l'auth.
    case launch_env do
      {:ok, human, env} ->
        with {:ok, env} <- maybe_put_auth_token(env, human),
             {:ok, env} <- maybe_put_git_identity(env, human, role),
             :ok <- Fleet.Credentials.Gate.validate(claude_dir_for(human), state.cap_profile) do
          {:ok, env}
        else
          {:error, {:credentials_invalid, _} = reason} -> {:error, reason}
          {:error, reason} -> {:error, {:auth_token_required, reason}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Source UNIQUE `Fleet.Credentials.Human` (pas de `id -un` shellé en double — sinon
  # spawn-ownership et commit-identity peuvent diverger, ce qui casserait la gate d'identité forge).
  # Fail-loud (raise), rattrapé par le try/rescue de `build/4` (converti en {:error, {:launch_env_unresolved, _}}).
  defp runtime_user, do: Fleet.Credentials.Human.current!()

  # ════════════════════════════════════════════════════════════════════════════════════════
  # MÉCANIQUE CREDENTIAL — ON N'Y TOUCHE PAS (et surtout pas pour la « durcir »).
  #
  # Le pod s'authentifie en montant le `.credentials.json` OAuth de SON humain (le `~/.claude`
  # de l'user runtime), bindé RW par le launcher. Ce fichier est PARTAGÉ et WRITABLE entre tous
  # les pods du même humain, et c'est VOULU : c'est la SEULE mécanique multi-agent que le vendor
  # supporte sous abonnement — N process Claude Code se coordonnent pour rafraîchir l'unique token
  # via un verrou cross-process sur `~/.claude/` (refresh natif, conçu « fleet-wide » côté vendor).
  #
  # Conséquence connue et ACCEPTÉE : un pod avec un shell peut lire le token de son PROPRE humain,
  # et peut écraser le fichier partagé. Ce n'est PAS un trou à fixer :
  #   - écraser/corrompre le creds = se suicider (sans creds, pas d'agent) → rien à défendre ;
  #   - le lire = le pod tourne DÉJÀ AS l'humain (il hérite de son UID) → c'est SON propre token,
  #     dans la frontière que l'OS lui accorde de toute façon.
  # Le seul vrai vecteur — lire le token d'un AUTRE humain — est rendu impossible ICI : le claudeDir
  # est dérivé PER-HUMAIN (`claude_dir_for/1` ; jamais un dir global partagé entre humains).
  #
  # Tout « fix » qui retirerait le bind RW, isolerait un credential par-pod, ou passerait par un
  # broker CASSE forcément un des trois piliers durs :
  #   - un token inference-only (`claude setup-token`) ne peut PAS tenir une session Remote Control
  #     (= notre mode interactif) ;
  #   - injecter l'access-token live = falaise ~8h sans refresh (déjà tenté, déjà reverté) ;
  #   - un apiKeyHelper / une clé API = facturation MÉTRÉE = sortie de l'abonnement (interdit).
  # Donc : per-humain OUI, partagé-writable OUI, broker NON. NE PAS « améliorer » ceci.
  # ════════════════════════════════════════════════════════════════════════════════════════
  def claude_dir do
    Application.get_env(:fleet_spawner, :claude_dir) || Path.join(Paths.runtime_home(), ".claude")
  end

  # Creds du pod = `~/.claude` de l'HUMAIN (= l'user runtime). Override config `:claude_dir` respecté
  # (tests / déploiement non-standard) ; sinon dérivé de son home passwd. Per-humain par construction
  # (cf. le gros bloc ci-dessus) — JAMAIS un claudeDir partagé entre humains.
  defp claude_dir_for(human) do
    Application.get_env(:fleet_spawner, :claude_dir) || claude_dir_from_passwd(human)
  end

  # Creds du pod = `.claude` dans le home de l'humain, résolu via `getent passwd`. Échec passwd =
  # erreur réelle (l'user de l'humain DOIT exister) → fail-loud, pas de `/home/<x>` deviné.
  defp claude_dir_from_passwd(human) do
    case passwd_home(human) do
      {:ok, home} -> Path.join(home, ".claude")
      :error -> raise "claude_dir: home introuvable (getent passwd #{inspect(human)}) — fail-loud"
    end
  end

  # Binaire vendor = celui de l'HUMAIN (~/.local/bin/claude résolu), posé en LCARS_VENDOR_BIN.
  # Honore le contrat bwrap_launch.sh « autorité = LCARS_VENDOR_BIN (spawner) » : sans ça, bwrap
  # retombe sur `command -v claude` = PATH du daemon → binaire système périmé (version périmée,
  # outil Monitor absent). readlink -f ⇒ bwrap_launch dérive VENDOR_SHARE = dirname(dirname(bin))
  # juste. Absent ⇒ on ne pose rien (fallback bwrap conservé).
  # Identité git du pod = l'HUMAIN du brief (author ET committer ; le pod commite EN TANT QUE
  # l'humain qui le run), résolue via le catalogue (`Fleet.Credentials.ForgeIdentity`). Remplace
  # un DÉFAUT COOPÉRATIF role-based de `bwrap_launch.sh` (GIT_AUTHOR=LCARS-$ROLE) : le rôle ne
  # signe plus l'identité — il passe en trailer `Co-authored-by`. bwrap_launch.sh forward ces
  # GIT_AUTHOR_*/GIT_COMMITTER_*. Catalogue absent → fail-loud {:forge_identity_unresolved,_}
  # (pas de pod sans identité vérifiable au push — la garantie reste côté MONDE, gate
  # `allowed_emails=[humain]`).
  defp maybe_put_git_identity(env, human, role) do
    case Fleet.Credentials.ForgeIdentity.for_role(role, human: human) do
      {:ok, id} ->
        {:ok,
         env
         |> Map.put("GIT_AUTHOR_NAME", id.author_name)
         |> Map.put("GIT_AUTHOR_EMAIL", id.author_email)
         |> Map.put("GIT_COMMITTER_NAME", id.committer_name)
         |> Map.put("GIT_COMMITTER_EMAIL", id.committer_email)}

      {:error, reason} ->
        {:error, {:forge_identity_unresolved, reason}}
    end
  end

  # Auth = mode `bind` UNIQUEMENT. bwrap monte le `.credentials.json` de l'humain en RW → refresh
  # OAuth natif (proactif 5min + réactif 401 + lockfile), full scope, PAS de falaise ~8h. Un mode
  # token_arg fuirait le token en argv (`--setenv CLAUDE_CODE_OAUTH_TOKEN`) ET ne refresherait pas
  # (expiresAt:null) → un eng long (>8h) perdrait l'auth en plein travail. Pas de toggle.
  defp maybe_put_auth_token(env, _human) do
    {:ok, Map.put(env, "LCARS_AUTH_MODE", "bind")}
  end

  # Binaire vendor posé en LCARS_VENDOR_BIN (honore le contrat bwrap_launch.sh) = `~/.local/bin/claude`
  # de l'HUMAIN (= l'user runtime), résolu via son home passwd. PAS de fallback `lcars` : le pod EST
  # l'humain, c'est SON binaire. Introuvable → fail-loud (sinon bwrap retombe sur `command -v claude`
  # = binaire système périmé, outil Monitor absent).
  defp maybe_put_vendor_bin(env, human) do
    case claude_bin_in_home(human) do
      bin when is_binary(bin) ->
        Map.put(env, "LCARS_VENDOR_BIN", bin)

      nil ->
        raise "vendor: binaire claude introuvable dans ~/.local/bin de #{inspect(human)} (fail-loud)"
    end
  end

  # Cherche `~/.local/bin/claude` dans le home passwd de `user`. Retourne le path réel
  # (readlink -f) ou `nil`. Le home vient de `getent passwd` (NSS), pas d'un `/home/<x>` deviné.
  defp claude_bin_in_home(user) when is_binary(user) do
    with {:ok, home} <- passwd_home(user),
         link = Path.join([home, ".local", "bin", "claude"]),
         true <- File.exists?(link) do
      case System.cmd("readlink", ["-f", link], stderr_to_stdout: true) do
        {out, 0} -> String.trim(out)
        _ -> link
      end
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp claude_bin_in_home(_), do: nil

  # Home de `user` via `getent passwd` (champ 6, 0-indexé 5). `{:ok, home}` | `:error`.
  defp passwd_home(user) do
    case System.cmd("getent", ["passwd", user], stderr_to_stdout: true) do
      {line, 0} ->
        case String.split(String.trim(line), ":") do
          fields when length(fields) >= 6 -> {:ok, Enum.at(fields, 5)}
          _ -> :error
        end

      _ ->
        :error
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end
end
