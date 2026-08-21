defmodule Fleet.Spawner.Pod.LaunchSpec do
  @moduledoc """
  Pod launch placement and environment — an island of PURE reads, extracted from
  `Fleet.Spawner.Pod`.

  Every function here resolves launch PATHS and ENV VARS from three inputs: the `cap_profile`
  (struct), the `opts` (spawn keyword) and the `pod_dir`. No state mutation, no Port, no timer,
  no FS write: deterministic computation only. The module does NOT read the Pod's `state` and
  calls back NO private of Pod — the Pod resolves its values (cap_profile, opts, pod_dir,
  claude_dir, launcher path…) and passes them as arguments. The cap-profile accessors
  (`name`/`containment`) are read from the SINGLE SOURCE `Fleet.CapProfile` (no re-decoding of
  the field).

  ## Contract (called by `Pod`)

  - `effective_project/2` — EFFECTIVE project (brief `opts[:project]` > static `spec["project"]`).
    Public because shared outside placement (`Pod.CompletedPayload`, bootstrap workspace): single source.
  - `rc_project/2` — project slug of the pod (opt `:project_slug`), or `nil`. Public because shared
    outside placement (`maybe_checkpoint_seed`): single source.
  - `pod_cwd/3` — cwd seen by the agent. Public because also called by recall (`maybe_recall_restore`).
  - `sandbox_home/2` — intra-pod home. Public because also passed to `McpProvision` (`:projecting` state).
  - `maybe_put_pod_cwd/4`, `maybe_put_sandbox_home/3`, `launch_home/3`, `permission_mode/1`,
    `skills_plugins_env/1`, `pod_mounts_env/2` — env builders, merged by the `:launching` state.
  - `remote_control?/1` — EFFECTIVE Desktop visibility, the ONE authority. Public because its three
    consumers sit in three places (slot capture, slot resume, and the vendor launcher through
    `LCARS_POD_REMOTE_CONTROL`); a second derivation is what it exists to prevent.
  """

  @doc """
  Pod's EFFECTIVE project: the brief (`opts[:project]`, dynamic) takes precedence over the
  cap-profile's static `spec["project"]`, default empty map. Drives the placement (project cwd)
  AND the end-of-step-run payload — hence the public visibility (single source, no re-derivation
  on the Pod side).
  """

  require Logger

  @spec effective_project(keyword() | nil, Fleet.CapProfile.t()) :: map()
  def effective_project(opts, cap_profile) do
    Keyword.get(opts || [], :project) || get_in(cap_profile.spec, ["project"]) || %{}
  end

  @doc """
  CLEAN project name of the pod, read from the EXPLICIT `:project` opt. `nil` when the caller names
  no project (permanent / admin pods → no cwd remap). Shared with the checkpoint seed-store.

  Confinement boundary: this `project` is a dispatch/recall input (untrusted) that ends up
  interpolated into paths/segments — cwd `/home/<project>`, intra-pod home, seed-store directory.
  So we require it to be a slug HERE, as early as possible: a malformed value (`../evil`, `a/b`) →
  `nil` (pod with no remap nor seed, neutral state) rather than a traversing `project` that would
  reach a `Path.join`. Single source → a single point to hold.

  ⚠ Its consumer `other_face_reference_path/3` builds a HOST path (`<face_root>/<project>`) whose
  documented authority is `Fleet.Layout.project_name/1`, not the slug. The two derivations differ on `_`, `.` and
  uppercase, so this would place a pod on a directory that does not exist. It does NOT, and the
  reason is a charset and not a contract: every onboarding entry point validates the project name
  against `^[a-z0-9][a-z0-9-]*[a-z0-9]$`, strictly inside what the slug preserves, so a project
  that HAS a directory has a name on which both derivations agree. Pinned as an invariant in
  `Fleet.LayoutTest` — widen that charset and the test parts company before a pod does.
  """
  @spec rc_project(keyword(), Fleet.CapProfile.t()) :: String.t() | nil
  def rc_project(opts, _cap_profile) do
    # The key is `:project_slug`, NOT `:project`: `:project` is ALREADY the project MAP of the brief
    # (`effective_project/2` — repo_path / base_branch / repo). Two different objects, two keys. A
    # slug parked under `:project` is silently swallowed by the map (last writer wins) and lands
    # here as a non-binary → `nil` → a pod with no remap, which is the exact silence below.
    #
    # READ, never re-parsed (2026-08-03). The slug is an EXPLICIT input now: every caller that
    # names a pod already holds it — it is what `rc_name` was BUILT from. Deriving it back out of
    # the label made the label a load-bearing structure: its format was frozen by this parse, so
    # adding the ticket number to the Desktop name (`tetris#42_engineer`) would have made
    # `Slug.valid?` fail → `nil` → a pod with NO cwd remap and NO seed, silently. One string was
    # doing two jobs; now the label is a label.
    #
    # No fallback to the old parse ON PURPOSE: it would not have saved a missed call site (the
    # parse fails on the new format anyway), it would only have hidden WHICH site was missed. The
    # refusal lives at the spawn choke point instead, where the other structural guards are.
    case Keyword.get(opts, :project_slug) do
      p when is_binary(p) ->
        if Fleet.Slug.valid?(p), do: p, else: nil

      _ ->
        nil
    end
  end

  @doc """
  Returns the cwd visible to the agent.

  Project workers use `/home/<project>`, orchestrators use their first RW mount, and other pods use
  their workspace path relocated under the sandbox home when applicable.
  """
  @spec pod_cwd(keyword(), Fleet.CapProfile.t(), Path.t()) :: String.t()
  def pod_cwd(opts, cap_profile, pod_dir) do
    cond do
      project = rc_project(opts, cap_profile) ->
        "/home/#{project}"

      rw = first_rw_mount(cap_profile, opts) ->
        rw

      true ->
        String.replace_prefix(
          pod_cwd_real(opts, cap_profile, pod_dir),
          pod_dir,
          sandbox_home(cap_profile, pod_dir)
        )
    end
  end

  @doc """
  Returns `/home/.pod` for bwrap containment and the real pod directory otherwise.
  """
  @spec sandbox_home(Fleet.CapProfile.t(), Path.t()) :: String.t()
  def sandbox_home(cap_profile, pod_dir) do
    if Fleet.CapProfile.bwrap?(cap_profile), do: "/home/.pod", else: pod_dir
  end

  defp first_rw_mount(cap_profile, opts) do
    (opts_mounts(opts) ++ cap_profile_mounts(cap_profile))
    |> Enum.find_value(fn m -> if (m["mode"] || m[:mode]) == "rw", do: m["path"] || m[:path] end)
  end

  defp pod_cwd_real(opts, cap_profile, pod_dir) do
    case effective_project(opts, cap_profile)["repo_path"] do
      nil -> pod_dir
      _ -> Fleet.Spawner.Pod.Paths.pod_workspace_path(pod_dir)
    end
  end

  @doc """
  Adds the agent-visible cwd and, for project workers, its real bind source to the launch environment.
  """
  @spec maybe_put_pod_cwd(map(), keyword(), Fleet.CapProfile.t(), Path.t()) :: map()
  def maybe_put_pod_cwd(env, opts, cap_profile, pod_dir) do
    env = Map.put(env, "LCARS_POD_CWD", pod_cwd(opts, cap_profile, pod_dir))

    if rc_project(opts, cap_profile),
      do: Map.put(env, "LCARS_POD_CWD_SRC", pod_cwd_real(opts, cap_profile, pod_dir)),
      else: env
  end

  @doc """
  Adds `LCARS_POD_HOME` for bwrap pods; host pods retain their native home.
  """
  @spec maybe_put_sandbox_home(map(), Fleet.CapProfile.t(), Path.t()) :: map()
  def maybe_put_sandbox_home(env, cap_profile, pod_dir) do
    if Fleet.CapProfile.bwrap?(cap_profile),
      do: Map.put(env, "LCARS_POD_HOME", sandbox_home(cap_profile, pod_dir)),
      else: env
  end

  @doc """
  Returns the native human home for host containment and the pod directory otherwise.
  """
  @spec launch_home(String.t(), Path.t(), Path.t()) :: Path.t()
  def launch_home("none", _pod_dir, claude_dir), do: Path.dirname(claude_dir)
  def launch_home(_containment, pod_dir, _claude_dir), do: pod_dir

  # DR-021
  @permission_modes ~w(default acceptEdits bypassPermissions plan)

  @doc """
  Returns the profile's closed-enum Claude permission mode, defaulting to `"default"` when absent.

  A present value outside the enum raises instead of being normalized.
  """
  @spec permission_mode(Fleet.CapProfile.t() | term()) :: String.t()
  def permission_mode(%Fleet.CapProfile{spec: spec}),
    do: bound_permission_mode(get_in(spec || %{}, ["invocation", "permission_mode"]) || "default")

  def permission_mode(_), do: "default"

  @doc """
  EFFECTIVE Desktop visibility of a pod — the ONE authority, obeyed by all three consumers.

  Visibility used to be derived twice, independently: `Fleet.CapProfile.remote_control?/1` on the
  Elixir side (the Desktop-slot capture and the slot resume) and a `jq` read of the same field in
  `claude_launch.sh` (the `--remote-control` flag and `remoteControlAtStartup`). Two derivations of
  one fact agree only as long as nothing tries to change it — and the moment something does, the
  half that is not reached produces a pod VISIBLE in Desktop whose slot is never captured nor
  resumed: visible now, a new slot every boot, which is the "12 archs" bug wearing a new hat.

  So this is the single site, and the launcher stops deriving: `LaunchEnv.build/4` exports the
  answer as `LCARS_POD_REMOTE_CONTROL` and the shell obeys it.

  The declaration is the FLOOR; the fleet's debug mode (`fleet_v2 start --debug` →
  `:debug_visibility`) is the only thing above it, and it is MONOTONE by construction — an `or`,
  never a replacement. A mode that could also CLOSE would let an operator ask for observability and
  lose a pod they had; and a mode that lies in either direction is worse than no mode, because the
  operator stops looking. So: debug can add a window, it can never take one away.

  The mode is fixed for the fleet's whole life, deliberately: this is read at LAUNCH, so it governs
  the pods spawned while it is on and does not retro-fit the ones already up. A pod's visibility is
  therefore a property of its own launch, not a fleet-wide state that shifts under it.
  """
  @spec remote_control?(Fleet.CapProfile.t() | term()) :: boolean()
  def remote_control?(cap_profile) do
    Fleet.CapProfile.remote_control?(cap_profile) or Fleet.Spawner.debug_visibility?()
  end

  @doc """
  Does this pod compress its Bash output before it enters the agent's context? THE authority.

  Composed by an **AND**, and the contrast with `remote_control?/1` one function above is the whole
  design: that one is an `or` because debug may only ADD a window, this one is an `and` because the
  fleet may only REMOVE compression. Both are monotone, in opposite directions, and the direction is
  forced by what is at stake rather than chosen — visibility that fails closed costs an operator a
  pane they had; compression that fails open costs an agent an error line it never saw, on a defect
  the agent then reports as absent.

  So a role that declared `false` keeps it whatever the fleet says, and a fleet knob set to `false`
  cuts every pod whatever the profiles say. Neither can force the lossy direction on the other.

  Read at LAUNCH, like its neighbour: a pod's compression is a property of its own launch, not a
  fleet-wide state that shifts under a pod already running.

  ⚠ **AUCUN APPELANT EN PRODUCTION AUJOURD'HUI, ET LE VERDICT DE CETTE FONCTION N'ATTEINT AUCUN
  LANCEMENT.** Vérifié par un walker indépendant : hors sa définition et son test, `output_compression?/1`
  n'est appelée nulle part dans `lib/`, `bin/`, `etc/`, `deploy/` ni `config/`. La composition
  ci-dessus est donc exacte et inerte.

  **Ce qui manque n'est ni la brique ni le knob** — la brique `vendor/token_saver/` est dans l'image
  (`COPY` présent au Dockerfile), testée par `shell_gate.sh`, et le champ est déclaré au schéma
  cap-profile. **Ce qui manque est le VÉHICULE, et il n'a jamais existé** : la compression passe par
  un hook `PreToolUse`, or **un pod ne peut pas exécuter de hook** — le monde qu'on lui projette ne
  monte que `plugins/` et `skills/`, `pod_settings_json/1` n'écrit aucune clé `hooks`, et le
  `.claude` humain est exclu À CAUSE de ses hooks. Le porteur v1 visait le tier `user`, que
  `--setting-sources` exclut sans condition : il n'aurait jamais tiré non plus (mesuré 2026-08-07,
  cf. `vendor/token_saver/VENDOR.md`, qui porte le mot et son anticorps).

  Conséquence pour un auteur de cap-profile : **déclarer `output_compression` ne change rien
  aujourd'hui**, dans les deux sens. Le « brancher » ne serait pas restaurer un porteur perdu mais
  **en inventer un** dans un monde projeté pour n'en monter aucun — une fonctionnalité avec une
  décision de conception derrière, pas une correction. Ce paragraphe est ce qui empêche de lire
  l'inertie comme un bug à réparer ici.
  """
  @spec output_compression?(Fleet.CapProfile.t() | term()) :: boolean()
  def output_compression?(cap_profile) do
    Fleet.CapProfile.output_compression?(cap_profile) and
      Fleet.Spawner.output_compression_allowed?()
  end

  defp bound_permission_mode(mode) when mode in @permission_modes, do: mode

  defp bound_permission_mode(other) do
    raise ArgumentError,
          "LaunchSpec: SECURITY REFUSAL — permission_mode #{inspect(other)} is out of the closed CLI " <>
            "enum #{inspect(@permission_modes)} (schema-bypassed profile). Pod projection refused — " <>
            "an invalid security setting is NOT normalized to a safe default."
  end

  @mount_modes ~w(ro rw)

  defp bound_mount_mode(mode) when mode in @mount_modes, do: mode

  defp bound_mount_mode(other) do
    raise ArgumentError,
          "LaunchSpec: SECURITY REFUSAL — mount mode #{inspect(other)} is out of the closed enum " <>
            "#{inspect(@mount_modes)} (schema-bypassed mount). Pod projection refused — an invalid " <>
            "mount mode is NOT normalized to ro."
  end

  @doc """
  Returns `LCARS_SKILLS_PLUGINS` with unique plugin prefixes from qualified `plugin:skill` entries.

  Unqualified skills are ignored; an empty result returns no environment entry.
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
  `LCARS_SKILLS_PATHS` = the FILTERED plain-skill dirs to bind RO into the pod's
  `~/.claude/skills/` (BL-6-22 — the delivery half `filter_skills` never had). NEWLINE-delimited
  `name:abs_path` entries — the `LCARS_POD_MOUNTS` pattern, NOT the plugins one above: plugins
  carry bare NAMES, these carry PATHS, and a space-separated format would shatter on a skills
  root containing a space. The first `:` separates (a skill name is a `Fleet.Slug`, no `:` in
  the alphabet), so a path containing `:` stays whole. The name is `Path.basename(path)` —
  legitimate BY CONSTRUCTION (`filter_skills` builds each path as `Path.join(skills_root, name)`;
  do NOT "improve" filter_skills to return tuples — that is the `SPBuilder.Composer` behaviour
  contract, with stubs and tests on it). Empty → `%{}` (no var, no bind loop).
  """
  @spec skills_paths_env([Path.t()]) :: map()
  def skills_paths_env([]), do: %{}

  def skills_paths_env(paths) when is_list(paths) do
    # DR-021, same refusal as `mounts_env`: a `\n`/`\r` INSIDE a path would INJECT an extra bind
    # line into the sandbox projection → REFUSE the projection (raise, caught by LaunchEnv.build's
    # try/rescue → clean pod-projection failure), never drop-and-launch.
    case Enum.find(paths, &String.match?(&1, ~r/[\n\r]/)) do
      nil ->
        :ok

      injecting ->
        raise ArgumentError,
              "LaunchSpec: SECURITY REFUSAL — newline in a skill path (LCARS_SKILLS_PATHS " <>
                "injection): #{inspect(injecting)}. Pod projection refused — an injecting " <>
                "bind is NOT dropped-and-launched."
    end

    %{
      "LCARS_SKILLS_PATHS" =>
        Enum.map_join(paths, "\n", fn path -> "#{Path.basename(path)}:#{path}" end)
    }
  end

  @doc """
  Serializes the system, profile, spawn and other-face mounts for bwrap.

  Earlier entries win on duplicate paths. Modes must be `ro` or `rw`; newline-bearing fields raise.

  THE PROJECT'S OPS TREE IS NOT HERE, and its absence is the point. Every project pod used to carry
  a read-only bind of `<ops_root>/<project>` — the runtime's own record: what was asked, what was
  judged, what was proven. It was there so that ONE role could read ONE file out of it, and the
  brief and the judging criterion now travel as text instead. A producer holding the ledger its own
  work is scored in is a hazard that buys nothing once the text is in its hands. The architect keeps
  the tree, through its explicit spawn `mounts:`, because reporting on the work IS its function.
  """
  @spec pod_mounts_env(Fleet.CapProfile.t(), keyword(), String.t(), Path.t() | nil) :: String.t()
  def pod_mounts_env(cap_profile, opts, claude_launch_path, pod_dir \\ nil) do
    (system_mounts(claude_launch_path) ++
       store_mounts() ++
       cap_profile_mounts(cap_profile) ++
       opts_mounts(opts) ++
       other_face_reference_mount(opts, cap_profile, pod_dir))
    |> Enum.uniq_by(fn m -> m["path"] || m[:path] end)
    |> mounts_env()
  end

  # ── LE MAGASIN D'OUTILLAGE ──────────────────────────────────────────────────────────────────
  #
  # DEUX MONTAGES, ET UN SEUL SERAIT UNE PANNE. L'arbre entier en `ro` — un pod n'installe rien,
  # c'est la propriete centrale du rail : un magasin writable le rendrait contournable par le pod,
  # ce que la garde humaine existe pour empecher. MAIS `cache/` est ecrit par pip, npm et cargo :
  # monte en lecture seule, le premier `pip install` du pod rend `EROFS` et un `CARGO_HOME` pointant
  # dedans fait exploser cargo a la premiere dependance.
  #
  # L'ORDRE PORTE LE SENS : bwrap applique les montages dans l'ordre declare, donc le `rw` du cache
  # doit venir APRES le `ro` de l'arbre pour le recouvrir. Les inverser rend le cache lisible et non
  # ecrivable, c'est-a-dire la panne ci-dessus avec l'air d'etre configure.
  #
  # LA RACINE SE LIT, ELLE NE SE DECLARE PAS : `LCARS_STORE_ROOT` vient du compose, qui en est le
  # seul proprietaire (`deploy/lib/store.sh` possede les noms de volumes). Absente ou non montee :
  # AUCUN montage, et le pod demarre — DR-023, deja paye sur `GIT_MIRROR` (« a spawn died on a
  # missing relic »). Un outillage manquant ralentit un pod, il ne le tue pas.
  defp store_mounts do
    case store_root() do
      nil ->
        []

      root ->
        [%{"mode" => "ro", "path" => root}] ++
          if File.dir?(Path.join(root, "cache")),
            do: [%{"mode" => "rw", "path" => Path.join(root, "cache")}],
            else: []
    end
  end

  @doc false
  @spec store_root() :: Path.t() | nil
  def store_root do
    case System.get_env("LCARS_STORE_ROOT") do
      root when is_binary(root) and root != "" -> if File.dir?(root), do: root, else: nil
      _unset -> nil
    end
  end

  # ── L'ENVIRONNEMENT D'OUTILLAGE ─────────────────────────────────────────────────────────────
  #
  # INSTALLER NE SUFFIT PAS — LE POD DOIT POUVOIR S'EN SERVIR, et c'est le trou le plus couteux a
  # diagnostiquer de tout ce rail : l'install sort verte, le pod compile toujours sans la toolchain,
  # et RIEN NE RELIE LES DEUX SYMPTOMES. Un pod ne voit que ce que `bwrap_launch.sh` lui monte et lui
  # `--setenv`. Le magasin monte (ci-dessus) rend l'arbre VISIBLE ; ceci le rend UTILISABLE.
  #
  # `KEY=VALUE` A PLAT, ET SURTOUT PAS UN `source`. Sourcer du shell fourni par un artefact
  # telecharge, dans le processus qui CONSTRUIT le bac a sable, rouvrirait dans le launcher
  # exactement le trou que le convergeur referme. Le pod recoit un RESULTAT, jamais un programme :
  # c'est au convergeur de jouer l'`env_script` d'un SDK une fois, dans le contexte du pod, et d'en
  # figer le delta ici.
  #
  # LA VALIDATION VIT ICI, cote Elixir, comme pour les montages — le bash ne valide rien, il deplie.
  @doc """
  The `LCARS_POD_TOOLCHAIN_ENV` payload: `KEY=VALUE` lines composed from `<store>/state/env.d/*.env`.

  Empty string when there is no store, no `env.d`, or nothing declared — the launcher then adds no
  `--setenv` at all and the pod's command line is what it is today, byte for byte.
  """
  @spec toolchain_env() :: String.t()
  def toolchain_env do
    case store_root() do
      nil -> ""
      root -> root |> Path.join("state/env.d") |> read_env_dir() |> Enum.join("\n")
    end
  end

  # DENYLIST CLOSE, PAS UNE HEURISTIQUE. `CARGO_HOME` n'est lu que par cargo : un pod Python qui le
  # porte ne perd rien. `CC` est lu par TOUT systeme de build. Un `CC=aarch64-linux-gnu-gcc` global,
  # et le premier pod Python qui installe un paquet a extension C native compile de l'ARM64 : `pip`
  # REUSSIT, et l'import echoue plus tard en « Exec format error », sans une ligne qui nomme
  # l'environnement de compilation. Une compilation croisee nomme sa toolchain dans SES PROPRES
  # fichiers de build, ou c'est lisible et versionne avec le projet.
  @universal_build_vars ~w(CC CXX LD AR NM RANLIB STRIP CFLAGS CXXFLAGS LDFLAGS CPPFLAGS)
  @key_re ~r/\A[A-Z_][A-Z0-9_]*\z/

  defp read_env_dir(dir) do
    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".env"))
        |> Enum.sort()
        |> Enum.flat_map(&read_env_file(Path.join(dir, &1)))

      {:error, :enoent} ->
        []

      {:error, reason} ->
        Logger.error(
          "LaunchSpec: toolchain env dir #{dir} present but UNREADABLE (#{inspect(reason)}) — " <>
            "the pod launches WITHOUT its toolchain environment. An installed toolchain it cannot see."
        )

        []
    end
  end

  defp read_env_file(path) do
    case File.read(path) do
      {:ok, body} ->
        body |> String.split("\n") |> Enum.flat_map(&parse_env_line(&1, path))

      {:error, reason} ->
        Logger.error("LaunchSpec: toolchain env file #{path} unreadable (#{inspect(reason)})")
        []
    end
  end

  defp parse_env_line(line, path) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" or String.starts_with?(trimmed, "#") ->
        []

      not String.contains?(trimmed, "=") ->
        raise ArgumentError,
              "LaunchSpec: REFUSAL — #{path} carries a line with no `=`: #{inspect(trimmed)}. " <>
                "This file is KEY=VALUE, never shell. Pod projection refused."

      true ->
        [key, value] = String.split(trimmed, "=", parts: 2)
        validate_env_pair(String.trim(key), value, path)
    end
  end

  # NEWLINE ET `\r` REFUSENT LE SPAWN — le meme geste que `mounts_env/1`, et pour la meme raison :
  # une valeur qui porte un saut de ligne casse le format de passage et fait apparaitre une seconde
  # variable que personne n'a declaree. `\r` est teste avec `\n` parce qu'il traverse `--setenv`
  # silencieusement et casse ensuite un `[[ "$VAR" == "attendu" ]]` de facon invisible.
  defp validate_env_pair(key, value, path) do
    cond do
      not Regex.match?(@key_re, key) ->
        raise ArgumentError,
              "LaunchSpec: REFUSAL — #{path} declares #{inspect(key)}, which is not a shell " <>
                "environment name (`[A-Z_][A-Z0-9_]*`). Pod projection refused."

      String.contains?(value, "\n") or String.contains?(value, "\r") ->
        raise ArgumentError,
              "LaunchSpec: SECURITY REFUSAL — newline in a toolchain env value for #{key} " <>
                "(#{path}). Pod projection refused — an injecting value is NOT dropped-and-launched."

      key in @universal_build_vars ->
        # DROPPED, NOT REFUSED, and the asymmetry is deliberate: a malformed file is a bug in the
        # producer and must stop the line; a universal build var is a POLICY breach whose blast
        # radius is other pods. Refusing the spawn would let one bad env.d file kill every pod on
        # the box — a worse failure than the one being prevented. The converger refuses it at
        # write time; this is the belt at read time.
        Logger.error(
          "LaunchSpec: #{key} DROPPED from #{path} — universal build variables are refused. " <>
            "Set globally they make every pod cross-compile: `pip` succeeds and the import fails " <>
            "later with `Exec format error`, naming nothing. A cross build declares its toolchain " <>
            "in its own build files."
        )

        []

      true ->
        ["#{key}=#{value}"]
    end
  end

  defp opts_mounts(opts), do: Keyword.get(opts || [], :mounts, [])

  # THE REFERENCE FACE IS PINNED, and this is the only place in the pod's world where that was not
  # already true. Its workspace is pinned (`pin_base_sha`), its order is pinned (`brief_sha`), its
  # matter is pinned (the lot's commit), its deliverable is pinned (`livrable_sha`) — the reference
  # was a LIVE `--ro-bind` of the host worktree, so it moved under a running pod every time the
  # human wrote in it or `WorktreeSync` rebased it. A producer could then compose against a state
  # that never existed as a whole, and had no way to say which one it read.
  #
  # Pinned by COPY at the face's head, into the pod's own directory, so the reference also survives
  # its source: a face removed under a running pod (`project_delete`) used to leave a dangling bind
  # the pod read as an empty tree, silently. Nothing outside the pod is depended on after spawn.
  #
  # The MOUNT POINT does not move: the copy is bound at the canonical `<face_root>/<project>`, so a
  # pointer written in a brief resolves exactly as before. Source and destination differ here and
  # nowhere else, which is why the mount protocol carries both.
  #
  # Missing something mid-run is not patched in place — the pod is nuked and relaunched on a
  # completed face (⚖ arbitrage user 2026-08-11). A frozen world you replace beats a live one you
  # cannot cite.
  defp other_face_reference_mount(opts, cap_profile, pod_dir) do
    with path when is_binary(path) <- other_face_reference_path(opts, cap_profile),
         dir when is_binary(dir) <- pod_dir,
         {:ok, pinned} <- pin_reference_face(path, dir) do
      [%{"mode" => "ro", "path" => pinned, "dst" => path}]
    else
      # No pod_dir (a caller that only builds env, e.g. a test) → the live bind, as before. A
      # materialisation failure is NOT fatal either: the reference is a convenience, and refusing
      # to launch a producer because its doc face could not be copied would trade a soft loss for
      # a hard one. It is logged loud.
      nil -> []
      _no_pod_dir_or_failed -> live_reference_mount(opts, cap_profile)
    end
  end

  defp live_reference_mount(opts, cap_profile) do
    case other_face_reference_path(opts, cap_profile) do
      nil -> []
      path -> [%{"mode" => "ro", "path" => path}]
    end
  end

  @doc """
  Copies the reference face at its CURRENT head into `<pod_dir>/ref/<basename>` and returns that
  path. `git archive` + `tar`, so the copy carries no `.git` and no back-reference to the source:
  after this call the pod's reference depends on nothing outside the pod.
  """
  @spec pin_reference_face(Path.t(), Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def pin_reference_face(source, pod_dir) do
    dest = Path.join([pod_dir, "ref", Path.basename(source)])
    tarball = Path.join(pod_dir, "ref-#{Path.basename(source)}.tar")

    with :ok <- require_repo_toplevel(source),
         {:ok, {_, 0}} <-
           Fleet.Credentials.Shell.git(
             ["-C", source, "archive", "--format=tar", "-o", tarball, "HEAD"],
             env: []
           ),
         :ok <- File.mkdir_p(dest),
         {:ok, {_, 0}} <- Fleet.Credentials.Shell.run("tar", ["-xf", tarball, "-C", dest]) do
      _ = File.rm(tarball)
      {:ok, dest}
    else
      other ->
        _ = File.rm(tarball)
        # One level of `{:error, _}`, whichever step failed: a caller matching on the CAUSE should
        # not have to know how many `with` clauses it travelled through.
        reason =
          case other do
            {:error, r} -> r
            r -> r
          end

        Logger.warning(
          "LaunchSpec: reference face #{source} NOT pinned (#{inspect(reason)}) — the pod falls " <>
            "back to the live bind, which moves under it"
        )

        {:error, reason}
    end
  end

  @doc """
  Materializes ONE object — a single file at a PINNED commit — into `<pod_dir>/obj/<safe>/<path>`,
  and returns the path to that file.

  This is `pin_reference_face/2`'s narrow sibling, and the narrowness is the whole point. Where the
  face pin archives the WHOLE tree at HEAD, this archives `git archive <sha> -- <path>`: the pod
  receives exactly `path`, at exactly `sha`, and nothing else — no other ticket's file, no earlier
  version (history lives in the object store, not in the archive), no `.git`. It is how a brief or a
  criteria doc reaches the pod that must act on it WITHOUT mounting the ops face and exposing the
  whole ledger — the third horn the `sevrage` skipped between "mount everything" and "mount nothing".

  The pod reads its mandate FROM this file, so the read is coupled to the sha by git's own object
  store: an address cannot return a different content, and the commit sha is the Merkle root that
  covers the blob. The mandate is honest by construction — nothing to hash, nothing to trust.

  `sha` must be a 40-hex commit id (fail-closed: an unpinned `HEAD` here would defeat the freeze).
  A `path` absent at `sha` makes `git archive` fail, surfaced as `{:error, _}` — never a silent
  empty mount that would let a pod act on nothing while looking supplied.
  """
  @spec pin_object(Path.t(), Path.t(), String.t(), String.t()) ::
          {:ok, Path.t()} | {:error, term()}
  def pin_object(source, pod_dir, sha, path)
      when is_binary(source) and is_binary(pod_dir) and is_binary(sha) and is_binary(path) do
    safe = String.replace(path, ~r"[^A-Za-z0-9._-]", "_")
    dest = Path.join([pod_dir, "obj", safe])
    tarball = Path.join(pod_dir, "obj-#{safe}.tar")

    with :ok <- require_commit_sha(sha),
         :ok <- require_repo_toplevel(source),
         {:ok, {_, 0}} <-
           Fleet.Credentials.Shell.git(
             ["-C", source, "archive", "--format=tar", "-o", tarball, sha, "--", path],
             env: []
           ),
         :ok <- File.mkdir_p(dest),
         {:ok, {_, 0}} <- Fleet.Credentials.Shell.run("tar", ["-xf", tarball, "-C", dest]) do
      _ = File.rm(tarball)
      {:ok, Path.join(dest, path)}
    else
      other ->
        _ = File.rm(tarball)

        reason =
          case other do
            {:error, r} -> r
            r -> r
          end

        Logger.warning(
          "LaunchSpec: object #{path}@#{String.slice(sha, 0, 7)} NOT pinned from #{source} " <>
            "(#{inspect(reason)}) — the pod cannot be given a provable mandate and must not start"
        )

        {:error, reason}
    end
  end

  # An unpinned reference here defeats the freeze it exists to guarantee: `HEAD`, a branch name, a
  # short sha would all archive SOMETHING, and the mandate would float. Only a full commit id passes.
  defp require_commit_sha(sha) do
    if Regex.match?(~r/\A[0-9a-f]{40}\z/, sha),
      do: :ok,
      else: {:error, {:not_a_commit_sha, sha}}
  end

  # `git -C <dir>` WALKS UP: pointed at a directory that is not itself a repository, it resolves the
  # ENCLOSING one and archives that. Measured, and it is not theoretical — the test fixtures live
  # under the LCARS checkout, so the first run copied the whole runtime into the pod instead of
  # failing. A source that is not its own toplevel is refused rather than approximated.
  defp require_repo_toplevel(source) do
    case Fleet.Credentials.Shell.git(["-C", source, "rev-parse", "--show-toplevel"], env: []) do
      {:ok, {out, 0}} ->
        same? = Path.expand(String.trim(out)) == Path.expand(source)
        if same?, do: :ok, else: {:error, {:not_a_face_repo, source, String.trim(out)}}

      other ->
        {:error, {:not_a_face_repo, source, other}}
    end
  end

  @doc """
  Returns the OTHER production face's worktree as a read-only reference for this pod.

  A producer on `code` gets `workshop`, a producer on `workshop` gets `code` — each one reads what it must
  compose with and may not edit. A branch that is neither face (a judge cloning a producer's head)
  and a missing worktree both return `nil`.

  NEVER `ops`, and no clause is needed to say so: no card can declare that face, so no producer
  clone ever sits on that branch and `face_of/1` never answers it here. `face_root/1` raises on
  anything outside the declared faces rather than guessing a directory.

  `roots` is a test seam: `%{"code" => path, "workshop" => path}`, defaulting to the layout.
  """
  @spec other_face_reference_path(keyword(), Fleet.CapProfile.t(), map()) :: String.t() | nil
  def other_face_reference_path(opts, cap_profile, roots \\ default_face_roots()) do
    with face when face in ["code", "workshop"] <-
           Fleet.Layout.face_of(effective_project(opts, cap_profile)["base_branch"]),
         project when is_binary(project) <- rc_project(opts, cap_profile),
         path = Path.join(Map.fetch!(roots, other_face(face)), project),
         true <- File.dir?(path) do
      path
    else
      _ -> nil
    end
  end

  defp other_face("code"), do: "workshop"
  defp other_face("workshop"), do: "code"

  defp default_face_roots,
    do: %{
      "code" => Fleet.Layout.face_root("code"),
      "workshop" => Fleet.Layout.face_root("workshop")
    }

  defp cap_profile_mounts(%Fleet.CapProfile{metadata: meta}) when is_map(meta) do
    Map.get(meta, "mounts") || Map.get(meta, :mounts) || []
  end

  defp cap_profile_mounts(_), do: []

  # bwrap already exposes /usr; launchers elsewhere need an explicit mount after /home is masked.
  defp system_mounts(claude_launch_path) do
    bin = Path.dirname(claude_launch_path)
    if String.starts_with?(bin, "/usr/"), do: [], else: [%{"mode" => "ro", "path" => bin}]
  end

  defp mounts_env(mounts) when is_list(mounts) do
    case Enum.find(mounts, &mount_has_newline?/1) do
      nil ->
        :ok

      injecting ->
        raise ArgumentError,
              "LaunchSpec: SECURITY REFUSAL — newline in a mount field (LCARS_POD_MOUNTS injection): " <>
                "#{inspect(injecting)}. Pod projection refused — an injecting mount is NOT dropped-and-launched."
    end

    Enum.map_join(mounts, "\n", fn m ->
      mode = bound_mount_mode(Map.get(m, "mode") || Map.get(m, :mode))
      path = Map.get(m, "path") || Map.get(m, :path)

      # `mode:src:dst` only when the two differ — the pinned reference face is the sole case, and
      # emitting a redundant third field everywhere would make every other mount look like it has
      # a translation to check.
      case Map.get(m, "dst") || Map.get(m, :dst) do
        nil -> "#{mode}:#{path}"
        dst -> "#{mode}:#{path}:#{dst}"
      end
    end)
  end

  defp mount_has_newline?(m) do
    # `dst` is a mount field like the other two: a field that reaches the env line without this
    # check is a field the injection guard does not cover.
    has_newline?(Map.get(m, "mode") || Map.get(m, :mode)) or
      has_newline?(Map.get(m, "path") || Map.get(m, :path)) or
      has_newline?(Map.get(m, "dst") || Map.get(m, :dst))
  end

  defp has_newline?(v), do: is_binary(v) and String.contains?(v, ["\n", "\r"])
end
