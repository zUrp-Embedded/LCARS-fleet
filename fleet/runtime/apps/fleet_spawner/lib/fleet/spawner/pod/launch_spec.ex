defmodule Fleet.Spawner.Pod.LaunchSpec do
  @moduledoc """
  Placement et environnement de lancement du pod — île de lectures PURES, extraite de
  `Fleet.Spawner.Pod`.

  Toutes les fonctions ici résolvent des CHEMINS et des ENV VARS de lancement à partir de
  trois entrées : le `cap_profile` (struct), les `opts` (keyword du spawn) et le `pod_dir`.
  Aucune mutation de state, aucun Port, aucun timer, aucune écriture FS : que du calcul
  déterministe. Le module ne lit PAS le `state` du Pod et ne rappelle AUCUN private de Pod —
  le Pod résout ses valeurs (cap_profile, opts, pod_dir, claude_dir, launcher path…) et les
  passe en arguments. Les accesseurs de cap-profile (`name`/`containment`) sont lus à la SOURCE
  UNIQUE `Fleet.CapProfile` (pas de re-décodage du champ).

  ## Contrat (appelé par `Pod`)

  - `effective_project/2` — projet EFFECTIF (brief `opts[:project]` > statique `spec["project"]`).
    Public car partagé hors-placement (`Pod.CompletedPayload`, bootstrap workspace) : source unique.
  - `rc_project/2` — nom de projet slugifié depuis `rc_name`, ou `nil`. Public car partagé
    hors-placement (`maybe_checkpoint_seed`) : source unique.
  - `pod_cwd/3` — cwd vu par l'agent. Public car aussi appelé par le recall (`maybe_recall_restore`).
  - `sandbox_home/2` — home intra-pod. Public car aussi passé à `McpProvision` (état `:projecting`).
  - `maybe_put_pod_cwd/4`, `maybe_put_sandbox_home/3`, `launch_home/3`, `permission_mode/1`,
    `skills_plugins_env/1`, `pod_mounts_env/2` — builders d'env, mergés par l'état `:launching`.
  """

  @doc """
  Projet EFFECTIF du pod : le brief (`opts[:project]`, dynamique) prime sur le `spec["project"]`
  statique du cap-profile, défaut map vide. Pilote le placement (cwd projet) ET le payload de
  fin-de-step-run — d'où la visibilité publique (source unique, pas de re-dérivation côté Pod).
  """
  @spec effective_project(keyword() | nil, Fleet.CapProfile.t()) :: map()
  def effective_project(opts, cap_profile) do
    Keyword.get(opts || [], :project) || get_in(cap_profile.spec, ["project"]) || %{}
  end

  @doc """
  Nom de projet PROPRE depuis `rc_name` (`<project>_<role>`, source canonique sanitizée par le
  dispatcher). `nil` si pas de rc_name (pods permanents / admin → pas de remap cwd). Partagé avec
  le checkpoint seed-store.

  Frontière de confinement : ce `projet` est l'UNIQUE dérivation du nom de projet depuis `rc_name`
  (entrée de dispatch/recall, non maîtrisée), et il finit interpolé dans des chemins/segments — cwd
  `/home/<project>`, home intra-pod, dossier seed-store. On exige donc qu'il soit un slug ICI, au plus
  tôt : un `rc_name` malformé (`../evil_role`, `a/b_role`) → `nil` (pod sans remap ni seed, état neutre)
  plutôt qu'un `projet` traversant qui atteindrait un `Path.join`. Source unique → un seul point à tenir.
  """
  @spec rc_project(keyword(), Fleet.CapProfile.t()) :: String.t() | nil
  def rc_project(opts, cap_profile) do
    with rc when is_binary(rc) <- Keyword.get(opts, :rc_name),
         role <- Fleet.CapProfile.name(cap_profile),
         stripped when stripped != rc <- String.replace_suffix(rc, "_" <> role, ""),
         true <- Fleet.Slug.valid?(stripped) do
      stripped
    else
      _ -> nil
    end
  end

  @doc """
  cwd VU PAR L'AGENT dans le pod (= `LCARS_POD_CWD` + base du slug recall). Pour un pod-PROJET,
  l'agent voit `/home/<project>` (containment : ni human ni pod_id) ; bwrap y bind le workspace
  RÉEL (`pod_cwd_real`). Sinon (pas de projet nommé) = le réel. Le pod_dir RÉEL ne bouge PAS
  (reste `/home/<human>/pods/...`) — seul le CWD intra-pod est remappé. Public car aussi appelé
  par le recall (`Scaffold.maybe_recall_restore`).
  """
  @spec pod_cwd(keyword(), Fleet.CapProfile.t(), Path.t()) :: String.t()
  def pod_cwd(opts, cap_profile, pod_dir) do
    cond do
      # Worker projet → /home/<project>.
      project = rc_project(opts, cap_profile) ->
        "/home/#{project}"

      # Orchestrateur → son mount RW déclaré (arch → /home/projects.work). Data-driven (cap-profile).
      rw = first_rw_mount(cap_profile) ->
        rw

      # Permanent / legacy (projet sans rc_name) → le chemin RÉEL relocalisé (pod_dir → sandbox_home).
      # Home-relocalisé : sandbox_home=/home/.pod → workspace/home relocalisés ; off → pod_dir = identité.
      true ->
        String.replace_prefix(
          pod_cwd_real(opts, cap_profile, pod_dir),
          pod_dir,
          sandbox_home(cap_profile, pod_dir)
        )
    end
  end

  @doc """
  Home INTRA-POD. bwrap → `/home/.pod` (le pod_dir réel masqué derrière) ; sinon (host) → le
  pod_dir réel (pas de relocalisation). Doit matcher `LCARS_POD_HOME` posé par
  `maybe_put_sandbox_home/3`. Public car aussi passé à `McpProvision` par l'état `:projecting`.
  """
  @spec sandbox_home(Fleet.CapProfile.t(), Path.t()) :: String.t()
  def sandbox_home(cap_profile, pod_dir) do
    # « Contenu par bwrap ? » délégué au prédicat d'AUTORITÉ `CapProfile.bwrap?/1` (pas de littéral
    # "bwrap" matché en dur). bwrap → /home/.pod (relocalisation sandbox) ; sinon (host) → pod_dir réel.
    if Fleet.CapProfile.bwrap?(cap_profile), do: "/home/.pod", else: pod_dir
  end

  # cwd d'un orchestrateur = son 1er mount RW (DÉJÀ bindé via LCARS_POD_MOUNTS, donc pas de bind à
  # créer). nil si aucun rw. Réutilise l'accesseur unique cap_profile_mounts (pas de logique dupliquée).
  defp first_rw_mount(cap_profile) do
    cap_profile
    |> cap_profile_mounts()
    |> Enum.find_value(fn m -> if (m["mode"] || m[:mode]) == "rw", do: m["path"] || m[:path] end)
  end

  # Workspace RÉEL (hôte) sous le pod_dir : `pod_dir/workspace` si projet cloné, sinon `pod_dir`.
  # C'est la SOURCE du bind cwd (bwrap mappe ce réel sur le `/home/<project>` vu par l'agent).
  defp pod_cwd_real(opts, cap_profile, pod_dir) do
    case effective_project(opts, cap_profile)["repo_path"] do
      nil -> pod_dir
      _ -> Fleet.Spawner.Pod.Paths.pod_workspace_path(pod_dir)
    end
  end

  @doc """
  Pose le cwd du pod (`LCARS_POD_CWD`, lu par bwrap_launch ; défaut launcher `$POD_DIR`). cwd = la
  branche CODE (`<pod_dir>/workspace`) quand un projet est cloné — l'agent démarre DANS son code,
  pas dans le pod_dir nu. La branche DOC est à côté (`<pod_dir>/work`). Pas de projet → cwd =
  pod_dir (pods permanents/memory-X sans repo). Builder d'env mergé par l'état `:launching`.
  """
  @spec maybe_put_pod_cwd(map(), keyword(), Fleet.CapProfile.t(), Path.t()) :: map()
  def maybe_put_pod_cwd(env, opts, cap_profile, pod_dir) do
    env = Map.put(env, "LCARS_POD_CWD", pod_cwd(opts, cap_profile, pod_dir))

    # Worker projet : le cwd `/home/<project>` est un REMAP du workspace réel → bwrap doit le binder
    # (LCARS_POD_CWD_SRC). Orchestrateur (mount catalogue) / permanent / legacy (relocalisés sous le
    # bind HOME) → déjà bindés, pas de SRC à créer.
    if rc_project(opts, cap_profile),
      do: Map.put(env, "LCARS_POD_CWD_SRC", pod_cwd_real(opts, cap_profile, pod_dir)),
      else: env
  end

  @doc """
  Relocalise le home intra-pod (bwrap UNIQUEMENT). `LCARS_POD_HOME=/home/.pod` → bwrap_launch
  masque le pod_dir réel derrière (SANDBOX_HOME) : l'agent ne voit ni human ni pod_id, et
  `ls /home` ne montre que les mounts. Host pods (containment none) : pas relocalisés (home réel).
  Builder d'env mergé par l'état `:launching`.
  """
  @spec maybe_put_sandbox_home(map(), Fleet.CapProfile.t(), Path.t()) :: map()
  def maybe_put_sandbox_home(env, cap_profile, pod_dir) do
    # bwrap UNIQUEMENT (prédicat d'autorité) : relocalise le home intra-pod. Host (none) = home réel, rien à poser.
    if Fleet.CapProfile.bwrap?(cap_profile),
      do: Map.put(env, "LCARS_POD_HOME", sandbox_home(cap_profile, pod_dir)),
      else: env
  end

  @doc """
  HOME du pod selon containment. host (`"none"`) = home réel de l'humain (claude → `~/.claude`
  natif, refresh OAuth) ; bwrap = pod_dir (ignoré sous le sandbox de toute façon). Le `claude_dir`
  est RÉSOLU côté `LaunchEnv` (`claude_dir_for/1` — creds, honore l'override config `:claude_dir`
  et fail-loud si le passwd de l'humain est introuvable) et passé ici : le HOME host = son parent
  (`Path.dirname`).
  """
  @spec launch_home(String.t(), Path.t(), Path.t()) :: Path.t()
  def launch_home("none", _pod_dir, claude_dir), do: Path.dirname(claude_dir)
  def launch_home(_containment, pod_dir, _claude_dir), do: pod_dir

  @doc """
  Mode permission du pod : `spec.invocation.permission_mode` du cap-profile, défaut `"default"`
  (→ `--permission-mode default`, listes allow/deny ENFORCED). Non-vide → claude_launch passe
  `--permission-mode <mode>` ; pour ré-ouvrir le bypass, un cap-profile pose `"bypassPermissions"`.
  Posé en `LCARS_PERMISSION_MODE` par `LaunchEnv.build/4`.
  """
  @spec permission_mode(Fleet.CapProfile.t() | term()) :: String.t()
  def permission_mode(%Fleet.CapProfile{spec: spec}),
    do: get_in(spec || %{}, ["invocation", "permission_mode"]) || "default"

  def permission_mode(_), do: "default"

  @doc """
  `LCARS_SKILLS_PLUGINS` = noms plugins uniques extraits des skills QUALIFIÉS `plugin:skill` du
  cap-profile `spec.knowledge.skills`. Consommé par `bin/bwrap_launch.sh` (mount-bind RO). Un
  skill non-qualifié (sans `:`) n'est PAS un plugin → filtré. Vide → pas d'env var
  (rétro-compatible) : rend `%{}` ou `%{"LCARS_SKILLS_PLUGINS" => "p1 p2"}`.
  """
  @spec skills_plugins_env(Fleet.CapProfile.t()) :: map()
  def skills_plugins_env(%Fleet.CapProfile{spec: spec}) do
    plugins =
      (spec || %{})
      |> Map.get("knowledge", %{})
      |> Kernel.||(%{})
      |> Map.get("skills", [])
      |> Kernel.||([])
      |> Enum.filter(&(is_binary(&1) and String.contains?(&1, ":")))
      |> Enum.map(&(&1 |> String.split(":", parts: 2) |> hd()))
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case plugins do
      [] -> %{}
      list -> %{"LCARS_SKILLS_PLUGINS" => Enum.join(list, " ")}
    end
  end

  @doc """
  Sérialise `LCARS_POD_MOUNTS` (lu par bwrap_launch, une ligne `mode:path` par mount) : mount
  SYSTÈME (dir des launchers) ++ mounts CATALOGUE du cap-profile (`metadata.mounts`).
  `claude_launch_path` est résolu côté Pod (config d'install) et passé ici.
  """
  @spec pod_mounts_env(Fleet.CapProfile.t(), String.t()) :: String.t()
  def pod_mounts_env(cap_profile, claude_launch_path) do
    mounts_env(system_mounts(claude_launch_path) ++ cap_profile_mounts(cap_profile))
  end

  # Mounts CATALOGUE (cap-profile-driven) : le monde projeté dans le sandbox bwrap est
  # DÉCLARÉ par le cap-profile (`metadata.mounts`), pas hardcodé dans le launcher. bwrap_launch les bind
  # (RO/RW) au MÊME path, après la tmpfs /home. Vide ⇒ aucun mount extra (worker bare). Inerte pour
  # containment: none (host = accès natif).
  defp cap_profile_mounts(%Fleet.CapProfile{metadata: meta}) when is_map(meta) do
    Map.get(meta, "mounts") || Map.get(meta, :mounts) || []
  end

  defp cap_profile_mounts(_), do: []

  # Mount SYSTÈME universel : le dir des launchers (= `dirname(claude_launch_path)`) doit être VISIBLE
  # dans le sandbox bwrap, car `claude_launch.sh` y tourne en PID1. `/usr/local/bin` l'était par accident
  # (`--ro-bind /usr`) ; depuis l'install (`/local/LCARS_v2/bin`) ou le source dev (`/home/.../bin`) il faut
  # le bind explicite. Dérivé du path launcher (= paramètre d'install) → suit le déploiement sans hardcode.
  # Passe par le canal catalogue `LCARS_POD_MOUNTS` (appliqué APRÈS `--tmpfs /home` → re-expose même un
  # chemin `/home/...`) ⇒ sanctuaire `bwrap_launch.sh` INTACT. Skip si déjà sous `/usr` (couvert par
  # `--ro-bind /usr` → bind redondant inutile ; cas du défaut legacy `/usr/local/bin`, dont les tests).
  defp system_mounts(claude_launch_path) do
    bin = Path.dirname(claude_launch_path)
    if String.starts_with?(bin, "/usr/"), do: [], else: [%{"mode" => "ro", "path" => bin}]
  end

  # Sérialise les mounts pour bwrap_launch (`LCARS_POD_MOUNTS`) : une ligne "mode:path" par mount.
  defp mounts_env(mounts) when is_list(mounts) do
    mounts
    |> Enum.map(fn m ->
      mode = Map.get(m, "mode") || Map.get(m, :mode)
      path = Map.get(m, "path") || Map.get(m, :path)
      "#{mode}:#{path}"
    end)
    |> Enum.join("\n")
  end

  defp mounts_env(_), do: ""
end
