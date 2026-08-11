defmodule Fleet.SPBuilder do
  use Boundary,
    deps: [
      Fleet.Slug,
      Fleet.EnvParse,
      Fleet.GitRef,
      Fleet.Layout,
      Fleet.Catalogue,
      Fleet.Event,
      Fleet.SchemaCache,
      Fleet.CapProfile,
      # BL-6-16: the reception filter guards the repo-CLAUDE.md door (RepoSections) —
      # foundation, shared with the Pilot-side adoption gate.
      Fleet.ReceptionFilter
    ],
    exports: []

  @moduledoc """
  System Prompt builder/composer (LCARS schema v2.5).

  Pure data transformer: composed `%Fleet.CapProfile{}` + modop bundles
  (sp.md fragments) + pod identifiers → composed `system-prompt.md`,
  `CLAUDE.md`, and filtered skills paths.

  No process, no state. Three public functions (`compose/3`,
  `compose_claude_md/3`, `filter_skills/2`) implementing the
  `Fleet.SPBuilder.Composer` behaviour.

  ## The 6 canonical injection levels

    * N0  — model weights (nothing at runtime)
    * N1  — Anthropic server prompt (console config)
    * N2  — `system-prompt.md` composed via `compose/3`
    * N2bis — `~/context/brief.md` brief-specific (referenced, not composed)
    * N3  — `~/.claude/CLAUDE.md` composed via `compose_claude_md/3`
    * N3bis — `~/.claude/skills/` filtered via `filter_skills/2`

  Vendor boundary: this module stays vendor-agnostic — it COMPOSES the content, it
  injects nothing. INJECTING the SP into the pod is done by the **N1 boundary**
  (`bin/claude_launch.sh` — the N1 boundary IS the `bin/` script), which reads the
  composed SP from `<pod_dir>/.lcars/system-prompt.md` and passes it to `claude` via
  **`--system-prompt-file`** (OUT of argv: an SP on the argv would leak via
  `/proc/<pid>/cmdline` and graze ARG_MAX; `.lcars/` is readable in-sandbox, unlike
  `.claude/` masked by the creds bind). The launch is an interactive REPL
  (Remote Control), never headless/metered.

  sha256 determinism: 2 runs on the same input produce an
  identical `stable_sha256` (stable parts only, excludes
  `pod_id`, `spawned_at`, `job_id`, `attempt_id`).

  ## Split-out

  Two concerns with their own data source are extracted (the compose facade + EEx
  templating + path resolution stays here):

    * `Fleet.SPBuilder.Monk` — resolution of the monk injection (YAML registry I/O);
      `resolve_monk_injection/2` stays the public API (defdelegate).
    * `Fleet.SPBuilder.RepoSections` — extraction of the named sections from the repo
      `CLAUDE.md` (markdown mini-parser).

  Path resolution (`modop_root`) is NOT extracted: these are the
  config-accessors for THIS facade's reads (role SP, modop fragments), cohesive
  with them — a "Paths" module would carry only two getters with no logic.
  """

  @behaviour Fleet.SPBuilder.Composer

  alias Fleet.SPBuilder.Monk
  alias Fleet.SPBuilder.RepoSections

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

  @doc "Publishes the validated prompt-artifact image; unreadable artifacts raise."
  defdelegate publish_image!(), to: Fleet.SPBuilder.Image, as: :publish!

  @doc "Returns a published role draft, `:not_found`, or `:unpublished`."
  defdelegate image_draft(role), to: Fleet.SPBuilder.Image, as: :draft

  @doc "Returns the published worker protocol or `:unpublished`."
  defdelegate image_worker_protocol(), to: Fleet.SPBuilder.Image, as: :worker_protocol

  @doc "Returns the published human protocol or `:unpublished`."
  defdelegate image_human_protocol(), to: Fleet.SPBuilder.Image, as: :human_protocol

  @doc "Returns modified/vanished image sources, or `:unpublished`."
  defdelegate image_drift(), to: Fleet.SPBuilder.Image, as: :drift

  @doc """
  Composes a system prompt from a cap profile and ordered modop bundles.

  Preloaded paths affect `stable_sha256`; `pod_id`, `job_id`, `attempt_id` and
  `spawned_at` are volatile. Missing, unsafe or malformed inputs return typed
  errors.
  """
  @impl Fleet.SPBuilder.Composer
  @spec compose(Fleet.CapProfile.t(), [String.t()], compose_opts()) ::
          {:ok, composed()} | {:error, term()}
  def compose(%Fleet.CapProfile{} = cap_profile, modop_bundles, opts \\ [])
      when is_list(modop_bundles) and is_list(opts) do
    with :ok <- validate_compose_opts(opts),
         {:ok, modop_fragments} <-
           read_modop_fragments(modop_bundles, cap_profile.catalogue_root),
         {:ok, subagent_fragment} <- read_subagent_template(cap_profile),
         {:ok, monk_inj} <- Monk.resolve_or_empty(cap_profile, opts) do
      preloaded_paths =
        Keyword.get(opts, :preloaded_paths, []) ++ monk_inj.corpus_paths

      modop_concat =
        modop_fragments_concat(modop_fragments) <>
          subagent_fragment <> Monk.persona_section(monk_inj)

      stable_concat =
        IO.iodata_to_binary([
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
  Composes the pod `CLAUDE.md` and includes selected level-two sections from a
  repository `CLAUDE.md` when supplied: Stack, Build, Test, Doc, Conventions,
  Commands and Gotchas.
  """
  @impl Fleet.SPBuilder.Composer
  @spec compose_claude_md(Fleet.CapProfile.t(), String.t() | nil, keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def compose_claude_md(%Fleet.CapProfile{} = cap_profile, repo_claude_md_path, _opts \\ []) do
    with {:ok, repo_sections} <- RepoSections.read(repo_claude_md_path) do
      assigns = [
        role: Fleet.CapProfile.name(cap_profile),
        containment: Fleet.CapProfile.containment(cap_profile),
        lifetime_scope: Fleet.CapProfile.lifetime_scope(cap_profile, "unknown"),
        repo_claude_md_sections: repo_sections
      ]

      render_template(:claude_md, assigns)
    end
  end

  @doc """
  Resolves plain whitelisted skills to absolute mount paths.

  Missing or unsafe plain skills return errors. Qualified `plugin:skill`
  entries are delivered separately and are excluded from filesystem checks.
  """
  @impl Fleet.SPBuilder.Composer
  @spec filter_skills(Fleet.CapProfile.t(), Path.t()) :: {:ok, [Path.t()]} | {:error, term()}
  def filter_skills(%Fleet.CapProfile{} = cap_profile, skills_root)
      when is_binary(skills_root) do
    # THE resolver, like every other reader — a role and the material it declares resolve from the
    # same search path, or a catalogue can carry a role it cannot equip (W-11: `starfleet` declares
    # `card-revision`, the skill followed the role into the system catalogue, and the permanent pod
    # respawn-looped every five seconds).
    roots = Fleet.Catalogue.search(skills_root, Fleet.Catalogue.rel(:skills))

    if roots == [] do
      {:error, :skills_root_missing}
    else
      whitelist = get_in(cap_profile.spec, ["knowledge", "skills"]) || []
      plain = Enum.reject(whitelist, &String.contains?(&1, ":"))

      case Enum.reject(plain, &Fleet.Slug.valid?/1) do
        [] ->
          {present, missing} =
            plain
            |> Enum.map(fn name ->
              {name, Enum.find(Enum.map(roots, &Path.join(&1, name)), &File.exists?/1)}
            end)
            |> Enum.split_with(fn {_name, path} -> path != nil end)

          case missing do
            [] -> {:ok, Enum.map(present, fn {_name, path} -> path end)}
            _ -> {:error, {:skills_missing, Enum.map(missing, fn {name, _path} -> name end)}}
          end

        unsafe ->
          {:error, {:skills_unsafe, unsafe}}
      end
    end
  end

  @doc """
  Resolves the cap profile's monk injection through `Fleet.SPBuilder.Monk`.
  """
  @spec resolve_monk_injection(Fleet.CapProfile.t(), keyword()) ::
          {:ok, Monk.injection()} | :not_a_monk | {:error, term()}
  defdelegate resolve_monk_injection(cap_profile, opts \\ []), to: Monk, as: :resolve

  defp validate_compose_opts(opts) do
    preloaded = Keyword.get(opts, :preloaded_paths, [])
    spawned_at = Keyword.get(opts, :spawned_at, DateTime.utc_now())

    cond do
      not (is_list(preloaded) and Enum.all?(preloaded, &is_binary/1)) ->
        {:error, {:bad_opt, {:preloaded_paths, preloaded}}}

      not match?(%DateTime{}, spawned_at) ->
        {:error, {:bad_opt, {:spawned_at, spawned_at}}}

      true ->
        :ok
    end
  end

  defp sp_image(nil), do: Fleet.SPBuilder.Image.published()
  defp sp_image(root) when is_binary(root), do: Fleet.SPBuilder.Image.published(root)

  defp read_modop_fragments([], _root), do: {:ok, []}

  # La racine vient du PROFIL (`catalogue_root`), pas d'un argument transporte a cote : les fragments
  # d'un role appartiennent au catalogue qui le declare. `nil` = le premier catalogue actif, ce que
  # veut un appelant sans projet en main.
  defp read_modop_fragments(modop_bundles, root) do
    case sp_image(root) do
      %{modop_sp: fragments} ->
        Enum.reduce_while(modop_bundles, {:ok, []}, fn name, {:ok, acc} ->
          case Map.fetch(fragments, name) do
            {:ok, content} -> {:cont, {:ok, [{name, content} | acc]}}
            :error -> {:halt, {:error, {:modop_bundle_missing, name}}}
          end
        end)
        |> case do
          {:ok, list} -> {:ok, Enum.reverse(list)}
          error -> error
        end

      nil ->
        read_modop_fragments_from_disk(modop_bundles)
    end
  end

  defp read_modop_fragments_from_disk(modop_bundles) do
    roots = Fleet.Catalogue.search(:modops)

    result =
      Enum.reduce_while(modop_bundles, {:ok, []}, fn name, {:ok, acc} ->
        # The name stays confined under EACH root it is tried in — the confinement is what makes an
        # untrusted name safe as a path segment, and trying a second root must not weaken it.
        case read_first_modop(roots, name) do
          {:ok, content} -> {:cont, {:ok, [{name, content} | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case result do
      {:ok, fragments} -> {:ok, Enum.reverse(fragments)}
      error -> error
    end
  end

  defp read_first_modop([], name), do: {:error, {:modop_bundle_missing, name}}

  defp read_first_modop([root | rest], name) do
    case Fleet.Slug.confined_join(root, name) do
      {:ok, dir} ->
        case File.read(Path.join(dir, "sp.md")) do
          {:ok, content} -> {:ok, content}
          {:error, _reason} -> read_first_modop(rest, name)
        end

      {:error, reason} ->
        {:error, {:modop_bundle_unsafe, {name, reason}}}
    end
  end

  defp read_subagent_template(%Fleet.CapProfile{
         spec: %{"invocation" => %{"subagent_template" => name}}
       })
       when is_binary(name) and name != "" do
    if Fleet.Slug.valid?(name) do
      case fetch_subagent_content(name) do
        {:ok, content} -> {:ok, "\n<!-- subagent-template:#{name} -->\n" <> content}
        :error -> {:error, {:subagent_template_missing, name}}
      end
    else
      {:error, {:subagent_template_unsafe, name}}
    end
  end

  defp read_subagent_template(_cap_profile), do: {:ok, ""}

  defp fetch_subagent_content(name), do: fetch_subagent_content(name, nil)

  defp fetch_subagent_content(name, root) do
    case sp_image(root) do
      %{subagent: templates} ->
        Map.fetch(templates, name)

      nil ->
        :subagent_templates
        |> Fleet.Catalogue.find("subagent-#{name}.md")
        |> File.read()
        |> case do
          {:ok, content} -> {:ok, content}
          {:error, _} -> :error
        end
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

  defp render_template(:sp, assigns), do: do_render("sp_template.eex", assigns)
  defp render_template(:claude_md, assigns), do: do_render("claude_md_template.eex", assigns)

  defp do_render(name, assigns) do
    case Fleet.SPBuilder.Image.template(name) do
      {:ok, source} -> {:ok, EEx.eval_string(source, assigns: assigns)}
      :not_found -> {:error, {:template_missing_from_image, name}}
      :unpublished -> {:ok, EEx.eval_file(template_path(name), assigns: assigns)}
    end
  rescue
    e -> {:error, {:template_render_failed, Exception.message(e)}}
  end

  defp template_path(name), do: Path.join(Fleet.Catalogue.sp_templates_root(), name)

  @doc """
  Returns the shared root used both to publish role drafts and to serve the
  unpublished disk fallback.
  """
  @spec sp_drafts_root() :: String.t()
  def sp_drafts_root do
    Application.get_env(:fleet_sp_builder, :sp_drafts_root) || Fleet.Catalogue.sp_drafts_root()
  end

  @doc """
  Path of a role's SP draft, looked up in the SYSTEM catalogue then the business one — the
  unpublished disk fallback's half of what the image does at publish time.

  Returns the business path when the role has no draft anywhere, so the caller's `:enoent` names
  the file an author would have to create. The two protocol files are NOT resolved this way: they
  are the operator's conversation contract, and only the business catalogue carries them.
  """
  @spec sp_draft_path(String.t()) :: Path.t()
  def sp_draft_path(role) when is_binary(role) do
    Fleet.Catalogue.find(:sp_drafts, "agent-#{role}-base.md")
  end
end
