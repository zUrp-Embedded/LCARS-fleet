defmodule Fleet.Spawner.Pod.Paths do
  @moduledoc """
  Résolution des CHEMINS du substrat pod — île de calcul PUR extraite de `Fleet.Spawner.Pod`.

  Un seul rôle : dériver, à partir d'un `pod_id` (+ scope du cap-profile + overrides `opts`/config),
  les deux empreintes disque d'un pod et leur racine scannable :

  - le **pod_dir** (`<pod_dir_root>/pod_<pod_id>` — clone git + `.lcars`/`.claude`/`issues`),
  - le **state.json** de recovery (`<state_fs_root>/<scope>/<pod_id>/state.json`) et sa racine.

  Toutes les valeurs descendent du HOME de l'humain qui lance la fleet (`runtime_home/0` =
  `System.user_home!()`, fleet-sous-l'humain) sauf override explicite (`opts[:pod_dir_root]` /
  `opts[:state_fs_root]` ou la config `:fleet_spawner`). Aucun state, aucun Port, aucun timer, aucune
  écriture FS : que de la résolution déterministe. Le module ne lit PAS le `state` du Pod ni ne rappelle
  un private de Pod — le Pod lui passe `pod_id`/`cap_profile`/`opts` en arguments. Dépend de
  `Fleet.CapProfile.lifetime_scope/2` (source unique du scope) et de la config `:fleet_spawner`, déjà
  des deps de l'app (aucun cycle).

  ## Contrat (appelé par `Pod`)

  - `pod_dir/2` (PUBLIC, aussi appelé par `PodWarden`) — pod_dir reconstructible du SEUL pod_id, ce qui
    rend le GC par scan possible (le warden dérive le pod_dir à effacer depuis la tombstone, sans cap_profile).
  - `state_fs_root/0` (PUBLIC, aussi balayé par `PodWarden`) — racine scannable des `state.json`.
  - `pod_dir_for/2`, `state_fs_path_for/3`, `runtime_home/0` — résolutions appelées par `Pod`
    (`initial_state`, `clear_terminal_snapshot`) et `Pod.LaunchEnv` (`claude_dir` → `runtime_home/0`) ;
    publiques car franchies depuis ces modules.
  """

  @doc """
  pod_dir d'un pod : `<pod_dir_root>/pod_<pod_id>` (clone git complet + `.lcars`/`.claude`/`issues`).
  Le cap_profile N'ENTRE PAS dans le calcul — le pod_dir ne dépend que du pod_id et de la base — donc il
  est reconstructible depuis le SEUL pod_id. C'est ce qui rend le GC par scan possible : le `PodWarden`
  trouve une tombstone (state.json) par son pod_id et en dérive le pod_dir à effacer, sans jamais avoir
  le cap_profile hors-contexte. Config `:fleet_spawner, :pod_dir_root`, défaut `~/pods`.
  """
  @spec pod_dir(String.t(), keyword()) :: String.t()
  def pod_dir(pod_id, opts \\ []) when is_binary(pod_id), do: pod_dir_for(pod_id, opts)

  def pod_dir_for(pod_id, opts) do
    # Le pod vit SOUS LE HOME DE L'HUMAIN (= l'user runtime) : `~/pods/pod_<id>`, 0700, isolé OS
    # gratis (le pod hérite de l'UID du runtime). Le home ENCODE déjà l'humain (pas de `/home/<human>`
    # construit). `:pod_dir_root` (opts ou config) = override tests/déploiement non-standard ; non-set
    # ⇒ home du runtime. `pod_<id>` = nom stable (pod_id = clé de recovery, stable pour --resume).
    base =
      Keyword.get(opts, :pod_dir_root) ||
        Application.get_env(:fleet_spawner, :pod_dir_root) ||
        Path.join(runtime_home(), "pods")

    Path.join(base, "pod_#{pod_id}")
  end

  def state_fs_path_for(pod_id, cap_profile, opts) do
    root = Keyword.get(opts, :state_fs_root, state_fs_root())
    scope = scope_for(Fleet.CapProfile.lifetime_scope(cap_profile, nil))
    Path.join([root, scope, pod_id, "state.json"])
  end

  @doc """
  Racine FS des snapshots `state.json` (chaque pod : `<root>/<scope>/<pod_id>/state.json`, scope ∈
  {pipes,runs,pods}). C'est la base SCANNABLE pour énumérer les tombstones — le pendant côté state de
  `PodTmux.sock_base/0` côté sockets. Config `:fleet_spawner, :state_fs_root`, défaut `~/.lcars/state`.
  Public car le `PodWarden` la balaie pour GC les pod_dirs orphelins. Un `opts[:state_fs_root]`
  (override par-spawn) prime au call-site de `state_fs_path_for`, mais le warden, lui, balaie la racine
  GLOBALE (config) — les spawns à racine custom (tests) sont hors de son rayon par construction.
  """
  @spec state_fs_root() :: String.t()
  def state_fs_root,
    do: Application.get_env(:fleet_spawner, :state_fs_root, default_state_fs_root())

  # Fleet sous l'humain : le state FS des pods suit le HOME de l'humain (= l'user runtime),
  # comme `~/pods` (pod_dir) et `~/.lcars/workspaces`, PAS `/var/lib/lcars`.
  # Override via env `LCARS_STATE_FS_ROOT` (→ `config :fleet_spawner, :state_fs_root`).
  # HOME irrésoluble = runtime cassé → fail-loud via `runtime_home()` (la source unique locale,
  # `System.user_home!()`), jamais un chemin fabriqué : l'état .lcars ne doit pas se disperser en silence.
  defp default_state_fs_root,
    do: Path.join(Fleet.Layout.state_dir(), "state")

  defp scope_for("pipe"), do: "pipes"
  defp scope_for("run"), do: "runs"
  # `forever` partage le scope FS `pods/` avec `one_shot` (les deux = pods avec
  # lifetime propre).
  defp scope_for("forever"), do: "pods"
  defp scope_for(_), do: "pods"

  # L'humain qui fait tourner la fleet = l'user du process runtime lui-même : les SEULS users de
  # l'instance sont les users fleet → l'user courant EST l'humain. Pas de config, pas de défaut
  # littéral (un défaut masquerait un trou de câblage au lieu de le faire échouer). Le pod, enfant
  # du runtime (Port/tmux), HÉRITE de cet UID → tourne dans le home de l'humain, bind ses creds. Si
  # demain quelqu'un d'autre installe LCARS, c'est SON user qui lance, SON home — rien à hardcoder.
  # Fail-loud si HOME/user irrésoluble (impossible en pratique, mais jamais rattrapé en silence).
  def runtime_home, do: System.user_home!()
end
