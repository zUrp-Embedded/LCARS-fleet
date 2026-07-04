defmodule Fleet.Credentials.Shell do
  @moduledoc """
  Exécution bornée PAR CONSTRUCTION d'une commande externe (git, et plus généralement tout binaire
  lent/réseau). La frontière qui rend INEXPRIMABLE un `System.cmd("git", …)` non borné
  sur le chemin PROJECT : un appel externe a TOUJOURS une deadline, et la deadline tue le process
  enfant — ET tous ses descendants — si elle expire.

  ## Pourquoi un wrapper, pas une discipline par call-site

  `System.cmd/3` n'a **aucun timeout natif**. Un git réseau hung (DNS lent, TLS qui pend, packfile
  interrompu) — ou pire, un git qui ouvre un PROMPT interactif faute de credential (sans TTY → pend à
  l'infini) — bloque le process appelant. Sur le chemin PROJECT ce process est un GenServer (le
  `Fleet.Spawner.Pod` qui clone, le `Fleet.Pilot.Poller` qui merge) : figé, il ne traite plus aucun
  message → **pod zombie / issue wedgé**. Ce module extrait le patron borné en helper réutilisable
  pour que la borne vive dans le TYPE de l'appel, pas dans la vigilance de chaque site.

  ## Deux propriétés DURES de la borne

  ### 1. La deadline tue le process-GROUP entier, pas juste le top-level

  Un `git` réseau ne s'exécute pas seul : il fork des helpers de transport (`git-remote-https`),
  des credential helpers, des filtres. Tuer le SEUL process top-level (`kill -KILL <os_pid>`) laisse
  ces descendants vivants après la deadline — ils continuent de consommer ressources/credentials et
  l'extraheader d'auth forge reste dans leur environ. On lance donc la commande dans sa **propre
  session/process-group** (`setsid`) et, à la deadline, on tue le **GROUPE entier**
  (`kill -KILL -<pgid>`) : le top-level ET toute sa descendance meurent ensemble. Vérifié au sol
  (2026-06-24) : un `bash -lc "sleep 30 & wait"` qui détache un descendant — `kill -KILL <top>` seul
  laisse le `sleep` ZOMBIE, alors que `kill -KILL -<pgid>` l'emporte avec.

  ### 2. La deadline est un MUR (wall-clock absolu), pas un idle-gap réarmable

  Un git réseau-hung ne pend pas forcément en silence : il peut GOUTTER de l'output (un octet toutes
  les `timeout-1` ms — keepalive, progress qui traîne). Une boucle `receive … after timeout_ms` qui
  se RÉARME à chaque `{:data}` ne tuerait JAMAIS ce git : chaque octet repousse l'échéance. C'est
  pourtant son scénario cible. On calcule donc une **deadline absolue** (`monotonic_now + timeout_ms`)
  UNE fois au démarrage ; la boucle `receive` n'attend que le temps RESTANT (`deadline - now`),
  jamais un `after timeout_ms` ré-armé. Le wall-clock total est borné quelle que soit la cadence de
  l'output. Vérifié au sol : un process qui émet en continu (drip) est tué à la deadline mur.

  ## Mécanisme du process-group (setsid + découverte du PGID)

  `setsid` place la commande dans une nouvelle session ⇒ elle devient leader de son propre
  process-group (`PGID == son PID`), distinct de celui du BEAM. On lance `setsid -w <cmd> <args>` :
  l'option `-w` garde le wrapper `setsid` VIVANT comme parent (sinon il fork-and-die et l'`os_pid`
  tenu par `Port.open` pointe sur un wrapper déjà mort, sans lien vers le vrai groupe). L'`os_pid`
  du port est alors le PID de `setsid` ; le vrai process est son UNIQUE enfant, dont on lit le PGID
  via `/proc/<child>/stat` (champ `pgrp`, Linux — cible documentée). La découverte du PGID se fait AU
  MOMENT du timeout (pas juste après l'open : `setsid -w` n'a pas forcément encore forké le process
  réel à cet instant → la découverte rendrait `nil`). Au timeout : `kill -s KILL -- -<child_pgid>`
  (groupe entier) puis fermeture du port et `kill` du wrapper `setsid`.

  ⚠ Le séparateur `--` du `kill` est LOAD-BEARING : `/usr/bin/kill` (util-linux) lit sinon le
  `-<pgid>` (commence par `-`) comme une OPTION et rend rc 0 SANS tuer le groupe (vérifié au sol
  2026-06-24). On passe donc le signal via `-s KILL` puis `--` puis la cible négative.

  Si la découverte du groupe échoue (race rare, /proc indisponible), on retombe sur
  `kill -KILL <os_pid>` du wrapper : dégradé honnête (le wrapper meurt, un descendant détaché PEUT
  survivre) — mais c'est le cas-limite, pas le chemin nominal, et il est journalisé implicitement par
  l'absence de groupe.

  ## Placement (cycle compile)

  `fleet_project_bootstrap` ne peut PAS dépendre de `fleet_workflow` ni `fleet_spawner` (cycle
  compile, cf. CLAUDE.md). `fleet_credentials` est SOUS les trois (dépendance commune) — c'est déjà le
  propriétaire de `Fleet.Credentials.ForgeAuth.git_env/0` pour la même raison. Le wrapper vit donc ici,
  atteignable par bootstrap, pipeline ET pilot sans introduire de cycle.

  ## Env par défaut

  Sans `:env`, l'env git système-side est injecté (`ForgeAuth.git_env/0` → `GIT_TERMINAL_PROMPT=0` +
  extraheader d'auth si configuré). Un caller non-git passe `env: [...]` (ou `env: []`).

  ## Résultat TYPÉ (non-ignorable)

      {:ok, {output, exit_code}}        # le process a rendu dans le délai (exit_code peut être ≠ 0)
      {:error, {:timeout, timeout_ms}}  # délai dépassé → process-GROUP OS TUÉ (SIGKILL) + port fermé
      {:error, {:exit, reason}}         # binaire introuvable / impossible à lancer ({:enoent, cmd})

  L'appelant DOIT matcher : un `{:error, {:timeout, _}}` n'est pas un succès silencieux.
  """

  require Logger

  @default_timeout_ms 30_000

  @type result ::
          {:ok, {String.t(), non_neg_integer()}}
          | {:error, {:timeout, pos_integer()}}
          | {:error, {:exit, term()}}

  # Neutralisation des MÉCANISMES git pilotables depuis le contenu d'un repo, à composer (`-c …`)
  # par TOUTE op git système-side (lancée par le runtime Elixir, hors bwrap) sur un workspace co-écrit
  # par un pod adversaire. SOURCE UNIQUE : un site qui oublie un de ces tournevis rouvre le trou ;
  # cette liste est LA définition de « git système-side neutralisé », tous les sites la composent
  # (ne JAMAIS recopier la liste ailleurs). Chaque flag rend INERTE un vecteur d'exécution de code que
  # le pod pourrait armer dans le `.git/config`, le `.gitattributes` ou un includeIf :
  #
  #   * `core.hooksPath=/dev/null` — aucun hook (`pre-commit`/`pre-push`/… posé dans `.git/hooks/`,
  #     ou un `core.hooksPath` pointé ailleurs par le pod) ne s'exécute côté monde.
  #   * `core.fsmonitor=` — désarme un programme fsmonitor (lancé par git au scan de l'index).
  #   * `core.sshCommand=` — désarme une commande ssh custom (lancée par fetch/push via ssh).
  #   * `diff.external=` — désarme le driver de diff externe (lancé par `git log -p`/`diff`/`show`,
  #     c.-à-d. par les ops de la gate de livrable qui scannent le diff `base..HEAD`).
  #   * `core.attributesFile=/dev/null` — neutralise le fichier d'attributs GLOBAL (un `filter=`/`diff=`
  #     déclaré hors-repo). NB : le `.gitattributes` IN-TREE n'est PAS désactivable par `-c` (git n'a
  #     aucun switch « disable all filters ») ; un `filter.<nom>.clean` in-tree à nom arbitraire reste
  #     exécutable par `git add`. Le seul verrou réel du vecteur IN-TREE est donc CÔTÉ CONTENU (refuser
  #     fail-closed le payload qui écrirait `.git/**` ou un `.gitattributes` armant `filter=`/`diff=`,
  #     fait par l'appelant qui place le contenu), pas ce flag. Ce flag ferme le vecteur config GLOBALE.
  @git_safe_config_args [
    "-c",
    "core.hooksPath=/dev/null",
    "-c",
    "core.fsmonitor=",
    "-c",
    "core.sshCommand=",
    "-c",
    "diff.external=",
    "-c",
    "core.attributesFile=/dev/null"
  ]

  @doc """
  Arguments `-c <clé>=<val>` à préfixer à TOUTE invocation `git` système-side sur un workspace
  co-écrit par un pod. Source UNIQUE de la neutralisation config (hooks, fsmonitor, sshCommand,
  diff.external, attributesFile global) ; les sites la composent au lieu de recopier la liste.
  Voir le commentaire de `@git_safe_config_args` pour le POURQUOI de chaque flag et la limite
  IN-TREE (les filtres `.gitattributes` du repo se ferment côté CONTENU, pas par `-c`).
  """
  @spec git_safe_config_args() :: [String.t()]
  def git_safe_config_args, do: @git_safe_config_args

  @doc """
  Exécute `git <args>` borné. `output` = stdout+stderr fusionnés (`stderr_to_stdout: true`, comme tous
  les sites git du codebase). Options :

    * `:timeout_ms` — deadline MUR (défaut #{@default_timeout_ms} ms). Au-delà, le process-GROUP git OS
      est tué (`SIGKILL` au groupe + fermeture du port) et on rend `{:error, {:timeout, timeout_ms}}`.
    * `:cd` — répertoire d'exécution.
    * `:env` — env du process enfant. **Défaut** : `Fleet.Credentials.ForgeAuth.git_env/0` (porte
      `GIT_TERMINAL_PROMPT=0` → un git sans credential ÉCHOUE au lieu de prompter/pendre). Passer
      `env: [...]` pour surcharger, `env: []` pour un env bare (mais on perd la borne anti-prompt —
      à éviter sur du git).
  """
  @spec git([String.t()], keyword()) :: result()
  def git(args, opts \\ []) when is_list(args) do
    env = Keyword.get_lazy(opts, :env, &Fleet.Credentials.ForgeAuth.git_env/0)
    run("git", args, Keyword.put(opts, :env, env))
  end

  @doc """
  Exécute `cmd <args>` borné — primitive générique sous `git/2`. Mêmes options que `git/2`, mais
  **sans** env par défaut (`env: []` si absent) : `git/2` est le seul à injecter `git_env/0`.

  ## La borne TUE le process-GROUP OS (pas juste le BEAM, pas juste le top-level)

  Lancé via `setsid` (nouveau process-group) puis `Port.open` pour tenir l'`os_pid`. À la deadline
  MUR (deadline absolue, pas idle-gap réarmable), on tue le **GROUPE entier** (`SIGKILL` à `-<pgid>`)
  ET on ferme le port → la commande et TOUS ses descendants (helpers de transport git, credential
  helpers, filtres) sont réellement morts. Pas de chemin pour appeler ce module sans deadline.
  """
  @spec run(String.t(), [String.t()], keyword()) :: result()
  def run(cmd, args, opts \\ []) when is_binary(cmd) and is_list(args) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    case {System.find_executable(cmd), System.find_executable("setsid")} do
      {nil, _} ->
        {:error, {:exit, {:enoent, cmd}}}

      {_exe, nil} ->
        # `setsid` est la condition du process-group tué-par-construction (Linux : toujours présent
        # via util-linux). Absent = on ne peut PAS garantir l'invariant « groupe entier tué » →
        # fail-closed plutôt qu'un faux sentiment de sécurité avec un `System.cmd` nu.
        {:error, {:exit, {:enoent, "setsid"}}}

      {exe, setsid} ->
        # On lance `setsid -w <exe> <args>` : `-w` garde le wrapper VIVANT (parent du vrai process),
        # sinon il fork-and-die et l'os_pid du port ne pointe sur rien d'utile. L'exécutable du port
        # est donc `setsid` ; ses args = `["-w", exe | args]`.
        port_opts =
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            :hide,
            {:args, ["-w", exe | args]},
            {:env, to_charlist_env(Keyword.get(opts, :env, []))}
          ]
          |> maybe_put_cd(Keyword.get(opts, :cd))

        port = Port.open({:spawn_executable, setsid}, port_opts)

        # `Port.info(:os_pid)` rend `nil` si le port est DÉJÀ fermé (commande ultra-rapide finie entre
        # open et info) → pas de groupe à tuer (le process est déjà parti) ; les messages {:data}/
        # {:exit_status} sont quand même dans la mailbox et `collect` les draine. nil = no-kill.
        os_pid = os_pid(port)

        # Deadline ABSOLUE calculée UNE fois : la boucle `receive` n'attend que le temps RESTANT, donc
        # un output qui goutte ne repousse jamais l'échéance (mur, pas idle-gap). Le PGID du groupe à
        # tuer est découvert au MOMENT du timeout (dans `terminate`), pas ici : juste après `Port.open`,
        # `setsid -w` n'a pas forcément encore forké le process réel (race) → la découverte immédiate
        # rendrait `nil`. À la deadline, le process tourne depuis `timeout_ms` → il est là, fork inclus.
        deadline = System.monotonic_time(:millisecond) + timeout_ms
        collect(port, os_pid, timeout_ms, deadline, [])
    end
  end

  defp os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> pid
      nil -> nil
    end
  end

  # PGID du process-group à tuer = celui de l'UNIQUE enfant de `setsid` (le vrai process). `setsid -w`
  # garde le wrapper vivant → le lien PPID est stable le temps de la découverte. On scanne `/proc` pour
  # le process dont le PPID = l'os_pid du wrapper, puis on lit son champ `pgrp` (champ 5 de
  # `/proc/<pid>/stat`, après le `state` qui suit le `(comm)` — comm peut contenir espaces/parenthèses,
  # d'où le découpage APRÈS le dernier `)`). Linux uniquement (cible documentée) ; toute anomalie → nil
  # (le timeout retombe sur `kill <os_pid>`, dégradé honnête).
  defp child_pgid(nil), do: nil

  defp child_pgid(parent_os_pid) do
    with {:ok, entries} <- File.ls("/proc"),
         child when is_binary(child) <- find_child(entries, parent_os_pid),
         {:ok, pgid} <- read_pgrp(child) do
      pgid
    else
      _ -> nil
    end
  end

  defp find_child(entries, parent_os_pid) do
    parent = to_string(parent_os_pid)

    Enum.find_value(entries, fn entry ->
      if pid_dir?(entry) and ppid_of(entry) == parent, do: entry, else: nil
    end)
  end

  defp pid_dir?(entry), do: Regex.match?(~r/^\d+$/, entry)

  # PPID = champ 4 de /proc/<pid>/stat ; pgrp = champ 5. Le format est :
  #   pid (comm) state ppid pgrp ...
  # `comm` peut contenir des espaces et des parenthèses → on coupe APRÈS le DERNIER `)` puis on
  # split sur l'espace : [state, ppid, pgrp, ...].
  defp ppid_of(pid), do: stat_field(pid, 1)

  defp read_pgrp(pid) do
    case stat_field(pid, 2) do
      nil ->
        :error

      s ->
        case Integer.parse(s) do
          {n, _} -> {:ok, n}
          :error -> :error
        end
    end
  end

  defp stat_field(pid, index) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, stat} ->
        stat
        |> String.split(")")
        |> List.last()
        |> String.trim()
        |> String.split(" ")
        |> Enum.at(index)

      _ ->
        nil
    end
  end

  # Boucle de réception bornée par DEADLINE MUR : accumule la sortie, rend `{:ok, {output, exit_code}}`
  # à l'exit ; à la deadline (temps RESTANT épuisé), tue le process-GROUP et ferme le port → `{:error,
  # {:timeout, timeout_ms}}`. La valeur du `after` est `deadline - now` (jamais ré-armée à `timeout_ms`) :
  # un output qui goutte fait progresser la boucle mais NE repousse PAS l'échéance.
  defp collect(port, os_pid, timeout_ms, deadline, acc) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        collect(port, os_pid, timeout_ms, deadline, [data | acc])

      {^port, {:exit_status, code}} ->
        {:ok, {acc |> Enum.reverse() |> IO.iodata_to_binary(), code}}
    after
      remaining ->
        terminate(port, os_pid)
        {:error, {:timeout, timeout_ms}}
    end
  end

  # Tuer à la deadline. Le PGID du groupe à tuer = celui du process RÉEL (l'enfant de `setsid -w`),
  # découvert MAINTENANT : le process tourne depuis `timeout_ms` (fork inclus) → la découverte est
  # fiable, contrairement à juste après l'open où `setsid -w` n'a pas forcément encore forké. Cible
  # PRIVILÉGIÉE = le process-GROUP entier : le top-level ET tous ses descendants (helpers de transport
  # git, filtres) meurent ensemble. Fallback si le PGID n'a pas pu être découvert (process déjà parti /
  # /proc indisponible) : on tue le wrapper `setsid` (dégradé honnête). `kill` best-effort (le process a
  # pu mourir entre-temps). Puis fermeture du port. nil = rien à tuer.
  defp terminate(port, os_pid) do
    _ =
      case child_pgid(os_pid) do
      pgid when is_integer(pgid) ->
        _ = kill_group(pgid)

        # Le wrapper setsid lui-même est leader d'une AUTRE session (celle du BEAM) → pas dans le
        # groupe tué ; on l'achève séparément pour ne pas laisser le port à demi-vivant.
        kill_pid(os_pid)

      nil ->
        kill_pid(os_pid)
    end

    safe_close(port)
  end

  # SIGKILL au process-GROUP entier (PID négatif = groupe en sémantique `kill(2)`). On passe le signal
  # via `-s KILL` et on SÉPARE l'argument-cible par `--` : sinon `/usr/bin/kill` (util-linux) lit le
  # `-<pgid>` (commence par `-`) comme une OPTION et NON comme une cible → il rend rc 0 SANS tuer le
  # groupe (vérifié au sol 2026-06-24 : `kill -KILL -<pgid>` laisse le descendant vivant ; `kill -s KILL
  # -- -<pgid>` le tue). Le `--` ferme le parsing d'options → le `-<pgid>` est interprété comme cible.
  defp kill_group(pgid) do
    System.cmd("kill", ["-s", "KILL", "--", "-#{pgid}"], stderr_to_stdout: true)
  end

  # SIGKILL à un PID unique (le wrapper setsid). `--` pour rester homogène (un PID positif n'est pas
  # ambigu, mais on garde la même forme défensive).
  defp kill_pid(nil), do: :ok

  defp kill_pid(pid) do
    System.cmd("kill", ["-s", "KILL", "--", to_string(pid)], stderr_to_stdout: true)
  end

  defp safe_close(port) do
    if Port.info(port), do: Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  # `Port.open env:` veut des charlists ({~c"K", ~c"V"}) ; on accepte les {String, String} du codebase.
  defp to_charlist_env(env) do
    Enum.map(env, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)
  end

  defp maybe_put_cd(opts, nil), do: opts
  defp maybe_put_cd(opts, cd), do: [{:cd, to_charlist(cd)} | opts]
end
