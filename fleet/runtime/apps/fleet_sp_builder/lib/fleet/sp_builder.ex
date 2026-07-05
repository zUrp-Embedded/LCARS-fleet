defmodule Fleet.SPBuilder do
  @moduledoc """
  System Prompt builder/composer (LCARS schema v2.5).

  Pure data transformer: composed `%Fleet.CapProfile{}` + modop bundles
  (sp.md fragments) + pod identifiers → composed `system-prompt.md`,
  `CLAUDE.md`, and filtered skills paths.

  No process, no state. Three public functions (`compose/3`,
  `compose_claude_md/3`, `filter_skills/2`) implementing the
  `Fleet.SPBuilder.Composer` behaviour.

  ## 6 niveaux d'injection canoniques

    * N0  — poids modèle (rien runtime)
    * N1  — server prompt Anthropic (config console)
    * N2  — `system-prompt.md` composé via `compose/3`
    * N2bis — `~/context/brief.md` brief-spécifique (référencé, pas composé)
    * N3  — `~/.claude/CLAUDE.md` composé via `compose_claude_md/3`
    * N3bis — `~/.claude/skills/` filtrés via `filter_skills/2`

  Frontière vendor : ce module reste vendor-agnostic — il COMPOSE le contenu, il
  n'injecte rien. L'INJECTION du SP dans le pod est faite par la **frontière N1**
  (`bin/claude_launch.sh`), qui lit le SP composé depuis
  `<pod_dir>/.lcars/system-prompt.md` et le passe à `claude` via **`--system-prompt-file`**
  (HORS argv : le SP en argv fuitait `/proc/<pid>/cmdline` et frôlait ARG_MAX, d'où le
  passage en mode fichier le 2026-06-14 — `.lcars/` est lisible in-sandbox, contrairement à
  `.claude/` masqué par le bind creds). REPL interactif (Remote Control), jamais headless.

  La frontière N1 EST le script `bin/` : il n'existe AUCUNE app claude-bridge ni module
  `Fleet.Claude.SPInjection`, et AUCUN mode metered (`claude -p`) — ne pas réintroduire ces
  réfs dans le moduledoc.

  Déterminisme sha256 : 2 exécutions sur même input produisent un
  `stable_sha256` identique (stable parts uniquement, exclut
  `pod_id`, `spawned_at`, `job_id`, `attempt_id`).

  ## Découpage

  Deux concerns à source de donnée propre sont extraits (la façade compose + templating
  EEx + résolution de paths reste ici) :

    * `Fleet.SPBuilder.Monk` — résolution de l'injection monk (I/O registry YAML) ;
      `resolve_monk_injection/2` reste l'API publique (defdelegate).
    * `Fleet.SPBuilder.RepoSections` — extraction des sections nommées du `CLAUDE.md`
      repo (mini-parser markdown).

  La résolution de paths (`sp_role_root`/`modop_root`) N'est PAS extraite : ce sont les
  config-accessors des lectures de CETTE façade (SP rôle, fragments modop), cohésifs
  avec elles — un module « Paths » ne porterait que deux getters sans logique.
  """

  @behaviour Fleet.SPBuilder.Composer

  alias Fleet.SPBuilder.Monk
  alias Fleet.SPBuilder.RepoSections

  # `stable_sha256` est un hex string `String.t()` (encodé via
  # `Base.encode16(case: :lower)`) — type plus précis que `binary()`
  # (sous-type plus large). Hex printable et
  # comparable en tests.
  @type composed :: %{
          sp_md: String.t(),
          stable_sha256: String.t(),
          metadata: %{
            pod_id: String.t() | nil,
            spawned_at: DateTime.t() | nil,
            modop_bundles_used: [String.t()]
          }
        }

  @type compose_opts :: [
          pod_id: String.t(),
          job_id: String.t(),
          attempt_id: String.t(),
          spawned_at: DateTime.t(),
          preloaded_paths: [String.t()],
          brief_path: String.t() | nil
        ]

  # ============================================================
  # Composer behaviour
  # ============================================================

  @doc """
  Compose le system prompt à partir d'une cap-profile et de modop bundles.

  ## Inputs

    * `cap_profile` — struct `%Fleet.CapProfile{}` issue de `Fleet.CapProfile.compose/2`
    * `modop_bundles` — liste ordonnée des noms de modops (ordre = précédence)
    * `opts` :
      * `:pod_id` (volatile, exclu du sha256 stable)
      * `:job_id` (volatile)
      * `:attempt_id` (volatile)
      * `:spawned_at` (volatile, DateTime, default `DateTime.utc_now/0`)
      * `:preloaded_paths` (paths archive-mode, **inclus** dans le hash stable)
      * `:brief_path` (référencé par path, pas composé dans le SP)

  ## Exit codes

    * `{:ok, %{sp_md, stable_sha256, metadata}}` — composition OK
    * `{:error, {:modop_bundle_missing, name}}` — modop sp.md absent
    * `{:error, {:sp_role_path_missing, path}}` — SP rôle base absent
    * `{:error, {:template_render_failed, reason}}` — erreur EEx
  """
  @impl Fleet.SPBuilder.Composer
  @spec compose(Fleet.CapProfile.t(), [String.t()], compose_opts()) ::
          {:ok, composed()} | {:error, term()}
  def compose(%Fleet.CapProfile{} = cap_profile, modop_bundles, opts \\ [])
      when is_list(modop_bundles) and is_list(opts) do
    with {:ok, sp_role_base} <- read_sp_role_base(cap_profile),
         {:ok, modop_fragments} <- read_modop_fragments(modop_bundles),
         {:ok, monk_inj} <- Monk.resolve_or_empty(cap_profile, opts) do
      preloaded_paths =
        Keyword.get(opts, :preloaded_paths, []) ++ monk_inj.corpus_paths

      modop_concat =
        modop_fragments_concat(modop_fragments) <> Monk.persona_section(monk_inj)

      stable_concat =
        IO.iodata_to_binary([
          sp_role_base,
          "\n",
          modop_concat,
          "\n",
          preloaded_paths_concat(preloaded_paths)
        ])

      stable_sha256 = :crypto.hash(:sha256, stable_concat) |> Base.encode16(case: :lower)
      spawned_at = Keyword.get(opts, :spawned_at, DateTime.utc_now())

      assigns = [
        pod_id: Keyword.get(opts, :pod_id, "n/a"),
        job_id: Keyword.get(opts, :job_id, "n/a"),
        attempt_id: Keyword.get(opts, :attempt_id, "n/a"),
        spawned_at: DateTime.to_iso8601(spawned_at),
        stable_sha256: stable_sha256,
        sp_role_base: sp_role_base,
        modop_fragments: modop_concat,
        preloaded_paths: preloaded_paths
      ]

      with {:ok, sp_md} <- render_template(:sp, assigns) do
        {:ok,
         %{
           sp_md: sp_md,
           stable_sha256: stable_sha256,
           metadata: %{
             pod_id: Keyword.get(opts, :pod_id),
             spawned_at: spawned_at,
             modop_bundles_used: modop_bundles
           }
         }}
      end
    end
  end

  @doc """
  Compose `CLAUDE.md` du pod (N3) — conventions pod + extraction sélective
  des sections du `CLAUDE.md` repo si fourni.

  Sections extraites du repo CLAUDE.md (si fourni) : `Stack`, `Build`,
  `Test`, `Conventions`, `Commands`, `Gotchas` — chaque header de niveau
  2 et son corps jusqu'au prochain header.

  ## Exit codes

    * `{:ok, claude_md_content}` — composition OK
    * `{:error, {:repo_claude_md_unreadable, path, reason}}` — path donné mais illisible
    * `{:error, {:template_render_failed, reason}}` — erreur EEx
  """
  @impl Fleet.SPBuilder.Composer
  @spec compose_claude_md(Fleet.CapProfile.t(), String.t() | nil, keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def compose_claude_md(%Fleet.CapProfile{} = cap_profile, repo_claude_md_path, _opts \\ []) do
    with {:ok, repo_sections} <- RepoSections.read(repo_claude_md_path) do
      assigns = [
        role: Fleet.CapProfile.name(cap_profile),
        containment: Fleet.CapProfile.containment(cap_profile),
        # lifetime_scope est nesté sous spec.invocation (schéma v2.5 +
        # cap-profiles canon ; cohérent avec check_lifetime_scope/1). L'ancien
        # chemin spec.lifetime_scope (pré-v2.5) rend toujours "unknown".
        lifetime_scope: Fleet.CapProfile.lifetime_scope(cap_profile, "unknown"),
        git_ops_denied: get_in(cap_profile.spec, ["scope", "git_ops_denied"]) || [],
        repo_claude_md_sections: repo_sections
      ]

      render_template(:claude_md, assigns)
    end
  end

  @doc """
  Filtre `skills_root` selon la whitelist `cap_profile.spec["knowledge"]["skills"]`.

  Retourne la liste des paths absolus à mount-bind dans le pod. Un skill
  PLAIN whitelisté mais absent du FS est un **fail-loud** (pas de filtrage
  silencieux — un pod ne doit pas réclamer un skill inexistant). Les skills
  QUALIFIÉS `plugin:skill` sont livrés via `LCARS_SKILLS_PLUGINS` (pas comme
  paths) → exclus de ce check de présence.

  ## Exit codes

    * `{:ok, [path_absolu, ...]}` — paths des skills plain présents (ordre conservé)
    * `{:error, {:skills_missing, [name, ...]}}` — skill(s) plain whitelisté(s) absent(s)
    * `{:error, :skills_root_missing}` — `skills_root` n'existe pas
  """
  @impl Fleet.SPBuilder.Composer
  @spec filter_skills(Fleet.CapProfile.t(), Path.t()) :: {:ok, [Path.t()]} | {:error, term()}
  def filter_skills(%Fleet.CapProfile{} = cap_profile, skills_root)
      when is_binary(skills_root) do
    if File.dir?(skills_root) do
      whitelist = get_in(cap_profile.spec, ["knowledge", "skills"]) || []

      # Les skills QUALIFIÉS `plugin:skill` sont livrés via
      # `LCARS_SKILLS_PLUGINS` (skills_plugins_env → bwrap charge le plugin),
      # PAS comme paths montés → exclus du check de présence sur disque.
      plain = Enum.reject(whitelist, &String.contains?(&1, ":"))

      {present, missing} =
        plain
        |> Enum.map(&{&1, Path.join(skills_root, &1)})
        |> Enum.split_with(fn {_name, path} -> File.exists?(path) end)

      # Un skill whitelisté mais ABSENT du disque est un fail-loud (erreur en amont
      # qui rend l'état « skill manquant » irreprésentable, pas rattrapé en aval) :
      # `{:error, {:skills_missing, names}}`, pas un filtrage silencieux du pod.
      case missing do
        [] -> {:ok, Enum.map(present, fn {_name, path} -> path end)}
        _ -> {:error, {:skills_missing, Enum.map(missing, fn {name, _path} -> name end)}}
      end
    else
      {:error, :skills_root_missing}
    end
  end

  @doc """
  Résout l'injection monk du cap-profile — API publique historique, déléguée à
  `Fleet.SPBuilder.Monk.resolve/2` (contrat détaillé, options et codes d'erreur
  documentés là-bas). `{:ok, %{persona_hint, corpus_paths}}` | `:not_a_monk` |
  `{:error, term()}`.
  """
  @spec resolve_monk_injection(Fleet.CapProfile.t(), keyword()) ::
          {:ok, Monk.injection()} | :not_a_monk | {:error, term()}
  defdelegate resolve_monk_injection(cap_profile, opts \\ []), to: Monk, as: :resolve

  # ============================================================
  # SP role base + modop fragments I/O
  # ============================================================

  defp read_sp_role_base(%Fleet.CapProfile{spec: spec}) do
    case get_in(spec, ["systemPrompt"]) do
      nil ->
        {:ok, ""}

      path when is_binary(path) ->
        full_path = Path.join(sp_role_root(), path)

        case File.read(full_path) do
          {:ok, content} -> {:ok, content}
          {:error, _reason} -> {:error, {:sp_role_path_missing, full_path}}
        end
    end
  end

  # Aucun modop demandé (chemin PROD : `SPBuilder.compose(cap, [], …)` côté pod.ex) → rien à lire,
  # `modop_root` jamais résolu : ce root sert UNIQUEMENT la fonctionnalité (config-pilotée) des fragments
  # de modop, non câblée dans la chaîne de spawn actuelle.
  defp read_modop_fragments([]), do: {:ok, []}

  defp read_modop_fragments(modop_bundles) do
    case modop_root() do
      {:ok, root} ->
        result =
          Enum.reduce_while(modop_bundles, {:ok, []}, fn name, {:ok, acc} ->
            path = Path.join([root, name, "sp.md"])

            case File.read(path) do
              {:ok, content} ->
                {:cont, {:ok, [{name, content} | acc]}}

              {:error, _reason} ->
                {:halt, {:error, {:modop_bundle_missing, name}}}
            end
          end)

        case result do
          {:ok, fragments} -> {:ok, Enum.reverse(fragments)}
          error -> error
        end

      :error ->
        {:error, :modop_root_unconfigured}
    end
  end

  defp modop_fragments_concat([]), do: ""

  defp modop_fragments_concat(fragments) do
    Enum.map_join(fragments, "\n\n", fn {name, content} ->
      "<!-- modop:#{name} -->\n#{content}"
    end)
  end

  defp preloaded_paths_concat([]), do: ""

  defp preloaded_paths_concat(paths) do
    "<!-- preloaded -->\n" <> Enum.map_join(paths, "\n", &"- #{&1}")
  end

  # ============================================================
  # Template rendering
  # ============================================================

  defp render_template(:sp, assigns), do: do_render(template_path("sp_template.eex"), assigns)

  defp render_template(:claude_md, assigns),
    do: do_render(template_path("claude_md_template.eex"), assigns)

  defp do_render(path, assigns) do
    {:ok, EEx.eval_file(path, assigns: assigns)}
  rescue
    e -> {:error, {:template_render_failed, Exception.message(e)}}
  end

  defp template_path(name) do
    Path.join([to_string(:code.priv_dir(:fleet_sp_builder)), "templates", name])
  end

  # ============================================================
  # Path resolution (config knobs for testability)
  # ============================================================

  # `sp_role_root` — base sous laquelle résout le chemin `spec.systemPrompt` d'un cap-profile. Défaut =
  # le canon cap-profiles BUNDLÉ (`Application.app_dir(:fleet_cap_profile, …)`, MÊME source que
  # `Fleet.CapProfile.root_dir/0`, dont sp_builder dépend déjà) → résout en RELEASE comme en dev SANS env.
  # L'ancien défaut relatif `"cap-profiles"` (relatif au CWD) donnait `:enoent` en release. Override config (test).
  defp sp_role_root do
    Application.get_env(:fleet_sp_builder, :sp_role_root) ||
      Application.app_dir(:fleet_cap_profile, "priv/canon/cap-profiles")
  end

  # `modop_root` — base des fragments SP de modop (`<root>/<name>/sp.md`). CONFIG-OBLIGATOIRE (fail-loud) :
  # les fragments canon vivent dans `fleet_workflow/priv/canon/modop-bundles` (Ring 3), HORS du graphe de
  # deps de sp_builder (Ring 1) → on ne peut PAS y pointer un défaut bundlé sans violer le ring (et
  # `Application.app_dir(:fleet_workflow, …)` lèverait « unknown application » en test isolé). Donc AUCUN
  # défaut relatif trompeur (l'ancien `"modop"` relatif au CWD = `:enoent` muet en release) : sans config,
  # `:error` → `read_modop_fragments` rend `{:error, :modop_root_unconfigured}` (fail-loud explicite). La
  # chaîne de spawn PROD ne passe aucun modop (`compose(cap, [], …)`) → ce root n'est jamais requis en prod.
  defp modop_root do
    case Application.fetch_env(:fleet_sp_builder, :modop_root) do
      {:ok, root} -> {:ok, root}
      :error -> :error
    end
  end
end
