defmodule Fleet.Starfleet.PeriodicCheck do
  @moduledoc """
  Plomberie PARTAGÉE des GenServers de check périodique starfleet (`MCPMonitor`, `MCPWatcher`).

  Les deux jumeaux portent le MÊME squelette : GenServer nommé + `Process.send_after/3` récursif
  (une seule échéance armée à tout instant : le tick exécute le check puis ré-arme la prochaine) +
  hook test `:check_now` (un call sync qui rejoue le code path complet du timer). Ce squelette vit
  ICI, sous forme de FONCTIONS appelées depuis leurs callbacks — pas de macro `use` : des fonctions
  suffisent, et un callback qui délègue explicitement reste auditable ligne à ligne (aucun code
  généré à reconstituer de tête).

  Chaque jumeau garde ce qui lui est PROPRE : son `init/1` (les champs d'état diffèrent — cible et
  statut pour le monitor, package/fetcher/versions pour le watcher), son `do_check/1` (le métier)
  et la FORME de sa réponse `:check_now` (`{:ok, status}` pour le monitor, `:ok` pour le watcher).
  Contrat minimal sur l'état : une map portant `interval_ms` (relu à CHAQUE ré-armement).

  NE PAS généraliser au-delà de ces deux modules : les autres GenServers périodiques du runtime
  (ex. `Fleet.Spawner.PodWarden`) ont leurs propres nuances (handle_continue, skip de tick) — les
  plier ici forcerait des paramètres spéculatifs. Deux clients réels, zéro client hypothétique.

  ## Contrat (appelé par `MCPMonitor` / `MCPWatcher`)

  - `start_link(module, opts)` — démarre le GenServer `module` nommé (`opts[:name]`, défaut le
    module lui-même — les tests injectent un nom unique pour co-exister).
  - `schedule(tick_message, interval_ms)` — arme la PROCHAINE échéance (`send_after` à `self()`,
    donc appelé DEPUIS le process GenServer : `init/1` et le handler de tick).
  - `tick(state, tick_message, do_check)` — corps du `handle_info` de tick : exécute `do_check.(state)`
    puis ré-arme → `{:noreply, new_state}`.
  - `check_now(state, do_check, reply)` — corps du `handle_call(:check_now, ...)` : même check que
    le timer, réponse construite par `reply.(new_state)` → `{:reply, _, new_state}`.
  """

  @spec start_link(module(), keyword()) :: GenServer.on_start()
  def start_link(module, opts) when is_atom(module) and is_list(opts) do
    GenServer.start_link(module, opts, name: Keyword.get(opts, :name, module))
  end

  @spec schedule(atom(), pos_integer()) :: reference()
  def schedule(tick_message, interval_ms)
      when is_atom(tick_message) and is_integer(interval_ms) and interval_ms > 0 do
    Process.send_after(self(), tick_message, interval_ms)
  end

  @spec tick(map(), atom(), (map() -> map())) :: {:noreply, map()}
  def tick(state, tick_message, do_check) when is_function(do_check, 1) do
    new_state = do_check.(state)
    _ = schedule(tick_message, new_state.interval_ms)
    {:noreply, new_state}
  end

  @spec check_now(map(), (map() -> map()), (map() -> term())) :: {:reply, term(), map()}
  def check_now(state, do_check, reply)
      when is_function(do_check, 1) and is_function(reply, 1) do
    new_state = do_check.(state)
    {:reply, reply.(new_state), new_state}
  end
end
