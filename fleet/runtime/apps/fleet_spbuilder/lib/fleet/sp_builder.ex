defmodule Fleet.SPBuilder do
  @moduledoc """
  System Prompt builder/composer (LCARS schema v2.5).

  Pure data transformer: composed `%Fleet.CapProfile{}` + modop bundles
  (sp.md fragments) + pod identifiers → composed `system-prompt.md`,
  `CLAUDE.md`, and filtered skills paths.

  No process, no state. Three public functions (`compose/3`,
  `compose_claude_md/3`, `filter_skills/2`) implementing the
  `Fleet.SPBuilder.Composer` behaviour.

  ## 6 niveaux d'injection canoniques (cf. architecture-cible §`fleet_spbuilder/`)

    * N0  — poids modèle (rien runtime)
    * N1  — server prompt Anthropic (config console)
    * N2  — `system-prompt.md` composé via `compose/3` (`--system-prompt-file`)
    * N2bis — `~/context/brief.md` mandate-spécifique (référencé, pas composé)
    * N3  — `~/.claude/CLAUDE.md` composé via `compose_claude_md/3`
    * N3bis — `~/.claude/skills/` filtrés via `filter_skills/2`

  Frontière vendor : ce module reste vendor-agnostic. Les flags
  `claude -p` (`--system-prompt-file`, etc.) sont appliqués par
  `Fleet.Claude.SPInjection` co-localisé `fleet_claude_bridge`
  (chantier 8), pas ici.

  Déterminisme sha256 : 2 exécutions sur même input produisent un
  `stable_sha256` identique (stable parts uniquement, exclut
  `pod_id`, `spawned_at`, `job_id`, `attempt_id`).
  """

  @behaviour Fleet.SPBuilder.Composer

  # `stable_sha256` est un hex string `String.t()` (encodé via
  # `Base.encode16(case: :lower)`). Précise la design note L93 qui
  # déclarait `binary()` (sous-type plus large). Hex printable et
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

  @repo_section_re ~r/^##\s+(Stack|Build|Test|Conventions|Commands|Gotchas)\b/m

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
         {:ok, monk_inj} <- monk_injection_or_empty(cap_profile, opts) do
      preloaded_paths =
        Keyword.get(opts, :preloaded_paths, []) ++ monk_inj.corpus_paths

      modop_concat =
        modop_fragments_concat(modop_fragments) <> monk_persona_section(monk_inj)

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
    with {:ok, repo_sections} <- read_repo_sections(repo_claude_md_path) do
      assigns = [
        role: get_in(cap_profile.metadata, ["name"]) || "unknown",
        containment: get_in(cap_profile.metadata, ["containment"]) || "unknown",
        lifetime_scope: get_in(cap_profile.spec, ["lifetime_scope"]) || "unknown",
        git_ops_denied: get_in(cap_profile.spec, ["scope", "git_ops_denied"]) || [],
        repo_claude_md_sections: repo_sections
      ]

      render_template(:claude_md, assigns)
    end
  end

  @doc """
  Filtre `skills_root` selon la whitelist `cap_profile.spec["knowledge"]["skills"]`.

  Retourne la liste des paths absolus à mount-bind dans le pod. Les
  entrées de la whitelist absentes du FS sont silencieusement ignorées
  (pas d'erreur — un skill absent = skill non disponible, pas une faute).

  ## Exit codes

    * `{:ok, [path_absolu, ...]}` — paths valides existants (ordre conservé)
    * `{:error, :skills_root_missing}` — `skills_root` n'existe pas
  """
  @impl Fleet.SPBuilder.Composer
  @spec filter_skills(Fleet.CapProfile.t(), Path.t()) :: {:ok, [Path.t()]} | {:error, term()}
  def filter_skills(%Fleet.CapProfile{} = cap_profile, skills_root)
      when is_binary(skills_root) do
    if File.dir?(skills_root) do
      whitelist = get_in(cap_profile.spec, ["knowledge", "skills"]) || []

      paths =
        whitelist
        |> Enum.map(&Path.join(skills_root, &1))
        |> Enum.filter(&File.exists?/1)

      {:ok, paths}
    else
      {:error, :skills_root_missing}
    end
  end

  @doc """
  Lot 4/6 (DN ring2/fleet_memory.md L478) — résout l'injection monk :
  si le cap-profile porte `spec.knowledge.{monk_registry, monk_instance}`,
  lit le registry YAML (kind MemoryRegistry), trouve l'entrée
  `monk_instance` → `{:ok, %{persona_hint, corpus_paths}}`. Sinon
  `:not_a_monk` (le flux compose/3 reste byte-identique chantier-2 —
  construction-additive, non-recouvrement).

  ## opts
    * `:monk_registry_root` — racine résolvant le path relatif du registry
      (test-seam ; défaut config `:fleet_spbuilder, :monk_registry_root`
      puis `Application.app_dir(:fleet_capprofile, "priv/canon/cap-profiles/monks")`).

  R0.8-brick1 : le champ `monk_registry` dans le cap-profile = basename
  (ex `alpha.yaml`) — le code resolve via `:monk_registry_root`. Le path
  doctrine `05_data-canon/...` est mort : R0.7 a réabsorbé in-repo.

  Fonction **pure** (lecture FS only, aucun process — Iron Law).
  """
  @spec resolve_monk_injection(Fleet.CapProfile.t(), keyword()) ::
          {:ok, %{persona_hint: String.t(), corpus_paths: [String.t()]}}
          | :not_a_monk
          | {:error, term()}
  def resolve_monk_injection(%Fleet.CapProfile{spec: spec}, opts \\ []) do
    knowledge = Map.get(spec, "knowledge", %{})
    registry_rel = Map.get(knowledge, "monk_registry")
    instance = Map.get(knowledge, "monk_instance")

    cond do
      is_nil(registry_rel) or is_nil(instance) ->
        :not_a_monk

      true ->
        root =
          Keyword.get(opts, :monk_registry_root) ||
            Application.get_env(:fleet_spbuilder, :monk_registry_root) ||
            Application.app_dir(:fleet_capprofile, "priv/canon/cap-profiles/monks")

        path = Path.join(root, registry_rel)

        with {:ok, reg} <- read_registry(path),
             {:ok, monk} <- find_monk(reg, instance) do
          {:ok,
           %{
             persona_hint: Map.get(monk, "persona_hint", ""),
             corpus_paths: Map.get(monk, "corpus_paths", [])
           }}
        end
    end
  end

  defp read_registry(path) do
    # R0.8-brick2 : `kind: MemoryRegistry` retiré (1 seul kind par dossier
    # `monks/*.yaml`, le path déclare le rôle). Validation = présence de
    # `spec.monks` au shape attendu, pas d'attribut `kind` embarqué.
    case YamlElixir.read_from_file(path) do
      {:ok, %{"spec" => %{"monks" => monks}} = reg} when is_list(monks) ->
        {:ok, reg}

      {:ok, _} ->
        {:error, {:not_a_memory_registry, path}}

      {:error, reason} ->
        {:error, {:registry_unreadable, path, reason}}
    end
  end

  defp find_monk(reg, instance) do
    monks = get_in(reg, ["spec", "monks"]) || []

    case Enum.find(monks, &(Map.get(&1, "name") == instance)) do
      nil -> {:error, {:monk_instance_not_found, instance}}
      monk -> {:ok, monk}
    end
  end

  # Wrapper compose/3 : :not_a_monk → injection vide (flux byte-identique
  # chantier-2) ; {:error,_} → propagé (fail-loud, GO-0/D2).
  defp monk_injection_or_empty(cap_profile, opts) do
    case resolve_monk_injection(cap_profile, opts) do
      {:ok, inj} -> {:ok, inj}
      :not_a_monk -> {:ok, %{persona_hint: "", corpus_paths: []}}
      {:error, _} = err -> err
    end
  end

  defp monk_persona_section(%{persona_hint: ""}), do: ""

  defp monk_persona_section(%{persona_hint: ph}) when is_binary(ph),
    do: "\n\n## Monk persona\n\n" <> ph

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

  defp read_modop_fragments(modop_bundles) do
    result =
      Enum.reduce_while(modop_bundles, {:ok, []}, fn name, {:ok, acc} ->
        path = Path.join([modop_root(), name, "sp.md"])

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
  # Repo CLAUDE.md section extraction (Stack|Build|Test|Conventions|Commands|Gotchas)
  # ============================================================

  defp read_repo_sections(nil), do: {:ok, ""}

  defp read_repo_sections(path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, extract_named_sections(content)}
      {:error, reason} -> {:error, {:repo_claude_md_unreadable, path, reason}}
    end
  end

  defp extract_named_sections(content) do
    lines = String.split(content, "\n")
    {sections_acc, current} = Enum.reduce(lines, {[], []}, &fold_section/2)

    [current | sections_acc]
    |> Enum.reverse()
    |> Enum.map(&Enum.reverse/1)
    |> Enum.filter(&named_section?/1)
    |> Enum.map_join("\n\n", &Enum.join(&1, "\n"))
  end

  defp fold_section(line, {acc, current}) do
    if String.match?(line, ~r/^##\s+/) do
      {[current | acc], [line]}
    else
      {acc, [line | current]}
    end
  end

  defp named_section?([]), do: false
  defp named_section?([first_line | _]), do: Regex.match?(@repo_section_re, first_line)

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
    Path.join([to_string(:code.priv_dir(:fleet_spbuilder)), "templates", name])
  end

  # ============================================================
  # Path resolution (config knobs for testability)
  # ============================================================

  defp sp_role_root do
    Application.get_env(:fleet_spbuilder, :sp_role_root, "cap-profiles")
  end

  defp modop_root do
    Application.get_env(:fleet_spbuilder, :modop_root, "modop")
  end
end
