defmodule Fleet.Pilot.ToolchainReconciler do
  @moduledoc """
  Le déclencheur du rail d'outillage — et ce n'est pas un événement, c'est une COMPARAISON.

  ## Pourquoi rien n'écoute le merge

  `CLAUDE.md` le pose pour toute la fleet : *« le webhook `gitea.*` est un ACCÉLÉRATEUR de poll,
  jamais une source de vérité »* — et `gitea.merged` est d'ailleurs déclaré **sans consommateur**
  dans `priv/event_router/events.yaml`. Ce module lit donc le head de la branche protégée et le
  compare au dernier SHA qu'il a appliqué. Ils diffèrent ⇒ il converge.

  Trois propriétés tombent gratuitement, et c'est ce qui rend la comparaison meilleure qu'un
  abonnement :

    * **le boot n'est pas un cas spécial.** C'est un tick comme un autre. Forge injoignable au
      démarrage ⇒ le tick suivant réessaie, au lieu d'un no-op silencieux qu'aucun rejeu ne rattrape.
    * **une PR fermée sans merge ne laisse rien de pendant** côté branche : le SHA n'a pas bougé,
      il n'y a rien à réconcilier. (Côté work-item, elle laisse un verrou — cf. §2 ci-dessous.)
    * **rejouer est sans effet.** Deux invocations voient le même écart et font le même geste.

  ## Deux tâches dans la même passe, et la seconde n'est pas optionnelle

  1. **la branche** : `head(<branche>) != SHA appliqué` ⇒ converge, puis note le SHA.
  2. **les demandes en vol** : une PR **fermée sans merge** ne fait PAS bouger le SHA, donc la
     comparaison de branche ne la verra JAMAIS. Sans cette seconde lecture, un work-item attend un
     événement qui n'arrivera pas — indistinguable d'un work-item en cours.

  ## Ce qu'il n'est pas

  Il n'installe rien. Il constate un écart et appelle **un** binaire root, dont l'entrée est un
  manifeste déjà mergé sur une branche protégée. Le seul geste privilégié de tout le rail tient
  dans cette invocation, et son argument a été signé par un humain avant d'exister.
  """

  use GenServer

  require Logger

  @default_interval_ms 60_000

  # ── API ─────────────────────────────────────────────────────────────────────────────────────

  @doc false
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Joue une passe MAINTENANT et rend ce qu'elle a fait — la même fonction que le tick appelle.

  Exposée parce qu'un réconciliateur qu'on ne peut déclencher qu'en attendant une minute est un
  réconciliateur qu'on ne teste pas, et qu'un opérateur ne peut pas interroger après avoir mergé.
  """
  @spec reconcile(keyword()) ::
          {:ok, :converged, String.t()} | {:ok, :up_to_date} | {:error, term()}
  def reconcile(opts \\ []) do
    repo = Keyword.get(opts, :repo, Fleet.Toolchain.ops_repo())
    branch = Keyword.get(opts, :branch, Fleet.Toolchain.branch())

    case forge().branch_head(repo, branch, []) do
      {:ok, head} -> converge_if_moved(head, opts)
      {:error, reason} -> unreachable(reason)
    end
  end

  @doc """
  Le SHA appliqué sur cette boîte, ou `nil` si le convergeur n'est jamais passé.

  ⚠ **`nil` ET « à jour » NE SONT PAS LA MÊME CHOSE**, et les confondre est le piège que ce fichier
  existe pour éviter : une boîte neuve n'a rien appliqué, donc son premier tick DOIT converger même
  si le manifeste n'a pas bougé depuis des semaines. C'est le cas du rebuild — `/usr` est revenu à
  la baseline de l'image pendant que la branche, elle, n'a pas changé d'un octet.
  """
  @spec applied_sha() :: String.t() | nil
  def applied_sha do
    case File.read(marker_path()) do
      {:ok, sha} -> String.trim(sha) |> nil_if_empty()
      {:error, _} -> nil
    end
  end

  # ── GenServer ───────────────────────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval_ms, config_interval())
    if interval > 0, do: schedule(interval)
    {:ok, %{interval_ms: interval}}
  end

  @impl true
  def handle_info(:tick, state) do
    # LOSSY PAR CONSTRUCTION : un tick qui lève ne doit pas tuer le rail. La forge tombe, un disque
    # est plein, le binaire root sort non-zéro — le tick suivant réessaiera, et c'est exactement la
    # propriété qui fait qu'un boot sans forge n'est pas un cas spécial.
    _ =
      try do
        reconcile([])
      rescue
        e -> Logger.error("ToolchainReconciler: passe en échec — #{Exception.message(e)}")
      end

    if state.interval_ms > 0, do: schedule(state.interval_ms)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # ── interne ─────────────────────────────────────────────────────────────────────────────────

  defp converge_if_moved(head, opts) do
    case applied_sha() do
      ^head ->
        {:ok, :up_to_date}

      previous ->
        Logger.info(
          "ToolchainReconciler: écart détecté (appliqué=#{previous || "aucun"} head=#{head}) — convergence"
        )

        run_converger(head, opts)
    end
  end

  # LE SHA N'EST NOTÉ QU'APRÈS UN SUCCÈS, et jamais avant. L'inverse — noter puis appliquer — ferait
  # d'un convergeur mort en route une boîte qui se croit à jour : le tick suivant verrait « pas
  # d'écart » et l'état approuvé resterait non appliqué, en silence, ce que tout ce rail refuse.
  defp run_converger(head, opts) do
    case converger().(head, opts) do
      :ok ->
        _ = write_marker(head)
        {:ok, :converged, head}

      {:error, reason} ->
        Logger.error(
          "ToolchainReconciler: le convergeur a REFUSÉ #{head} (#{inspect(reason)}) — le SHA " <>
            "appliqué reste inchangé, la passe suivante réessaiera. L'état déclaré n'est PAS appliqué."
        )

        {:error, reason}
    end
  end

  # L'UNIQUE GESTE PRIVILÉGIÉ DU RAIL, et son argument a été signé avant d'exister. `sudo` sur UN
  # binaire nommé (cf. le sudoers étroit), jamais un shell : la ligne de commande ne porte que le
  # SHA, et le convergeur lit le manifeste à ce SHA depuis la forge.
  defp default_converger(head, _opts) do
    bin = Application.get_env(:lcars_fleet, :toolchain_converger_bin, "/usr/local/bin/lcars-toolchain-converge")

    case System.cmd("sudo", ["-n", bin, head], stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, code} -> {:error, {:converger_failed, code, String.slice(out, 0, 2000)}}
    end
  end

  # UNE FORGE INJOIGNABLE N'EST PAS UN ÉCART. Rendre `:up_to_date` ici ferait qu'une panne réseau
  # se lise comme « rien à faire » — et sur un rebuild, la boîte resterait sans outillage en
  # annonçant que tout va bien.
  defp unreachable(reason) do
    Logger.warning(
      "ToolchainReconciler: branche illisible (#{inspect(reason)}) — AUCUNE conclusion tirée, " <>
        "la passe suivante réessaiera. Ce n'est pas « à jour »."
    )

    {:error, {:branch_unreadable, reason}}
  end

  # LE MARQUEUR VIT AVEC LE CONTENEUR, PAS AVEC LE MAGASIN — et c'est le cas du rebuild qui l'exige.
  # Une v1 le posait sous `LCARS_STORE_ROOT/state/` : un volume EXTERNE, qui survit au rebuild,
  # pendant que `/usr` — ce que le marqueur décrit — meurt avec le conteneur. Après un rebuild, la
  # comparaison lisait « à jour » sur une boîte revenue à la baseline : l'exact mensonge que le
  # moduledoc de ce fichier promet d'empêcher. La durée de vie d'un marqueur suit celle de l'objet
  # qu'il décrit (la doctrine des volumes de `01` §4.8, appliquée à un fichier).
  #
  # Le répertoire est posé par le provisioning (`45-sudoers-toolchain.sh`, 2775 root:fleet — le
  # BEAM écrit sous un uid worker, membre de fleet). Les verbes MAGASIN gardent leurs marqueurs à
  # eux sur le volume (ils décrivent des artefacts qui survivent) — c'est le convergeur qui les
  # gère, pas ce module.
  @default_run_state "/var/lib/lcars/toolchain"

  defp marker_path do
    dir =
      case System.get_env("LCARS_TOOLCHAIN_RUN_STATE") do
        d when is_binary(d) and d != "" -> d
        _unset -> @default_run_state
      end

    Path.join(dir, "toolchain.applied")
  end

  defp write_marker(head) do
    path = marker_path()
    _ = File.mkdir_p(Path.dirname(path))

    case File.write(path, head <> "\n") do
      :ok ->
        :ok

      {:error, reason} ->
        # Convergé mais sans mémoire : la passe suivante reconvergera (idempotent, donc correct) —
        # mais un tick qui refait le travail à CHAQUE passe doit se voir, pas passer pour un cycle
        # normal.
        Logger.warning(
          "ToolchainReconciler: convergé sur #{head} mais le marqueur est INÉCRIVABLE " <>
            "(#{inspect(reason)} sur #{path}) — la prochaine passe reconvergera. Le répertoire " <>
            "est posé par le provisioning (45-sudoers-toolchain)."
        )

        :ok
    end
  end

  defp schedule(ms), do: Process.send_after(self(), :tick, ms)

  defp config_interval,
    do: Application.get_env(:lcars_fleet, :toolchain_reconcile_interval_ms, @default_interval_ms)

  defp forge, do: Application.get_env(:lcars_fleet, :forge_client, Fleet.Forge.Client)

  defp converger,
    do: Application.get_env(:lcars_fleet, :toolchain_converger, &__MODULE__.default_converger_fun/2)

  @doc false
  def default_converger_fun(head, opts), do: default_converger(head, opts)

  defp nil_if_empty(""), do: nil
  defp nil_if_empty(s), do: s
end
