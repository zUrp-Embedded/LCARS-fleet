defmodule Fleet.Credentials.Shell do
  @moduledoc """
  Exécution bornée PAR CONSTRUCTION d'une commande externe (git, et plus généralement tout binaire
  lent/réseau). MOVE-1/MA-22 — la frontière qui rend INEXPRIMABLE un `System.cmd("git", …)` non borné
  sur le chemin PROJECT : un appel externe a TOUJOURS une deadline, et la deadline tue le process
  enfant (port → SIGKILL) si elle expire.

  ## Pourquoi un wrapper, pas une discipline par call-site

  `System.cmd/3` n'a **aucun timeout natif**. Un git réseau hung (DNS lent, TLS qui pend, packfile
  interrompu) — ou pire, un git qui ouvre un PROMPT interactif faute de credential (sans TTY → pend à
  l'infini, MA-22) — bloque le process appelant. Sur le chemin PROJECT ce process est un GenServer (le
  `Fleet.Spawner.Pod` qui clone, le `Fleet.Pilot.Poller` qui merge) : figé, il ne traite plus aucun
  message → **pod zombie / ticket wedgé**. Le patron borné existait déjà ponctuellement
  (`Fleet.Pipeline.Git.run_push` : `Task.async` + `yield(timeout) || shutdown(:brutal_kill)`) ; ce
  module l'EXTRAIT et le DURCIT en helper réutilisable pour que la borne vive dans le TYPE de l'appel,
  pas dans la vigilance de chaque site.

  ## La deadline tue le process OS (durcissement vs le patron historique)

  Vérifié au sol (2026-06-23) : `Task.shutdown(:brutal_kill)` tue le **Task BEAM** mais ne ferme PAS le
  port `System.cmd` ni ne tue le binaire enfant → un git/sleep qui pend SURVIT détaché (le GenServer
  n'est plus figé, mais le process git fuit, continuant à consommer ressources/OAuth). On lance donc
  via `Port.open` pour tenir l'`os_pid` ; à la deadline on envoie `SIGKILL` à l'os_pid PUIS on ferme le
  port → le process externe est réellement mort. C'est ce qui ferme le wedge « pod zombie » de bout en
  bout (le patron `Task` ne le faisait qu'au niveau BEAM).

  ## Placement (cycle compile)

  `fleet_project_bootstrap` ne peut PAS dépendre de `fleet_pipeline` ni `fleet_spawner` (cycle
  compile, cf. CLAUDE.md). `fleet_credentials` est SOUS les trois (dépendance commune) — c'est déjà le
  propriétaire de `Fleet.Credentials.ForgeAuth.git_env/0` pour la même raison. Le wrapper vit donc ici,
  atteignable par bootstrap, pipeline ET pilot sans introduire de cycle.

  ## Env par défaut

  Sans `:env`, l'env git système-side est injecté (`ForgeAuth.git_env/0` → `GIT_TERMINAL_PROMPT=0` +
  extraheader d'auth si configuré). Un caller non-git passe `env: [...]` (ou `env: []`).

  ## Résultat TYPÉ (non-ignorable)

      {:ok, {output, exit_code}}        # le process a rendu dans le délai (exit_code peut être ≠ 0)
      {:error, {:timeout, timeout_ms}}  # délai dépassé → process OS TUÉ (SIGKILL) + port fermé
      {:error, {:exit, reason}}         # binaire introuvable / impossible à lancer ({:enoent, cmd})

  L'appelant DOIT matcher : un `{:error, {:timeout, _}}` n'est pas un succès silencieux.
  """

  @default_timeout_ms 30_000

  @type result ::
          {:ok, {String.t(), non_neg_integer()}}
          | {:error, {:timeout, pos_integer()}}
          | {:error, {:exit, term()}}

  @doc """
  Exécute `git <args>` borné. `output` = stdout+stderr fusionnés (`stderr_to_stdout: true`, comme tous
  les sites git du codebase). Options :

    * `:timeout_ms` — deadline (défaut #{@default_timeout_ms} ms). Au-delà, le process git OS est tué
      (`SIGKILL` à l'os_pid + fermeture du port) et on rend `{:error, {:timeout, timeout_ms}}`.
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

  ## La borne TUE le process OS (pas juste le BEAM)

  Le patron historique (`Fleet.Pipeline.Git.run_push` : `Task.async` + `Task.yield` +
  `Task.shutdown(:brutal_kill)`) borne le **BEAM** (le GenServer ne reste pas figé), MAIS — vérifié au
  sol 2026-06-23 — `brutal_kill` tue le Task BEAM **sans fermer le port** ni tuer le `System.cmd`
  enfant : le process git/sleep SURVIT détaché et continue de consommer ressources/credentials. Pour
  fermer le wedge de bout en bout (MA-22 : « pas de pod zombie »), on lance via `Port.open` pour TENIR
  l'`os_pid` du process enfant et, à la deadline, on FERME le port ET on envoie `SIGKILL` à l'os_pid →
  le process externe est réellement mort. Pas de chemin pour appeler ce module sans deadline.
  """
  @spec run(String.t(), [String.t()], keyword()) :: result()
  def run(cmd, args, opts \\ []) when is_binary(cmd) and is_list(args) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    case System.find_executable(cmd) do
      nil ->
        {:error, {:exit, {:enoent, cmd}}}

      exe ->
        port_opts =
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            :hide,
            {:args, args},
            {:env, to_charlist_env(Keyword.get(opts, :env, []))}
          ]
          |> maybe_put_cd(Keyword.get(opts, :cd))

        port = Port.open({:spawn_executable, exe}, port_opts)

        # `Port.info(:os_pid)` rend `nil` si le port est DÉJÀ fermé (commande ultra-rapide finie entre
        # open et info) → pas d'os_pid à killer (le process est déjà parti) ; les messages {:data}/
        # {:exit_status} sont quand même dans la mailbox et `collect` les draine. nil = no-kill.
        os_pid = os_pid(port)
        collect(port, os_pid, timeout_ms, [])
    end
  end

  defp os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> pid
      nil -> nil
    end
  end

  # Boucle de réception bornée : accumule la sortie, rend `{:ok, {output, exit_code}}` à l'exit ; à la
  # deadline, SIGKILL l'os_pid (le process enfant ne survit pas) et ferme le port → `{:error, {:timeout}}`.
  defp collect(port, os_pid, timeout_ms, acc) do
    receive do
      {^port, {:data, data}} ->
        collect(port, os_pid, timeout_ms, [data | acc])

      {^port, {:exit_status, code}} ->
        {:ok, {acc |> Enum.reverse() |> IO.iodata_to_binary(), code}}
    after
      timeout_ms ->
        # Tuer l'os_pid AVANT de fermer le port : le SIGKILL OS garantit que git/sleep meurt même si
        # le close du port ne propage pas le signal (le trou du patron `brutal_kill`). `kill` best-effort
        # (le process a pu mourir entre-temps). nil = process déjà parti, rien à killer. Puis close port.
        if os_pid, do: System.cmd("kill", ["-KILL", to_string(os_pid)], stderr_to_stdout: true)
        safe_close(port)
        {:error, {:timeout, timeout_ms}}
    end
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
