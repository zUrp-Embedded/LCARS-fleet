defmodule Fleet.SPBuilder do
  # COMPILED domain boundary: deps = the declared inter-domain graph, exports = the
  # MEASURED cross-domain surface. The compiler refuses any violation — widening an
  # export or adding a dep is an API decision, visible in review.
  use Boundary,
    deps: [
      Fleet.Slug,
      Fleet.EnvParse,
      Fleet.GitRef,
      Fleet.Layout,
      Fleet.Event,
      Fleet.SchemaCache,
      Fleet.CapProfile
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

  Path resolution (`sp_role_root`/`modop_root`) is NOT extracted: these are the
  config-accessors for THIS facade's reads (role SP, modop fragments), cohesive
  with them — a "Paths" module would carry only two getters with no logic.

  **Last revised**: 2026-07-30
  """

  @behaviour Fleet.SPBuilder.Composer

  alias Fleet.SPBuilder.Monk
  alias Fleet.SPBuilder.RepoSections

  # `stable_sha256` is a hex string `String.t()` (encoded via
  # `Base.encode16(case: :lower)`) — a tighter type than `binary()`
  # (the wider supertype). Hex printable and
  # comparable in tests.
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
  Publishes the proven-good SP-artifact image (delegate — facade surface; ROOT at boot, gated
  `:fleet_sp_builder, :publish_image`). Raises on an unreadable root: do not boot.
  """
  defdelegate publish_image!(), to: Fleet.SPBuilder.Image, as: :publish!

  @doc """
  The role's SP draft from the published image (delegate for the spawner's Assets rail —
  `{:ok, content}` | `:not_found` closed-world | `:unpublished` → caller's disk fallback).
  """
  defdelegate image_draft(role), to: Fleet.SPBuilder.Image, as: :draft

  @doc """
  The pod's worker `protocole-user.md` from the published image (delegate for the spawner's Assets
  rail — `{:ok, content}` | `:unpublished` → caller's disk fallback). Same facade shape as
  `image_draft/1`: the Image module stays unexported, the domain surface carries the accessor.
  """
  defdelegate image_worker_protocol(), to: Fleet.SPBuilder.Image, as: :worker_protocol

  @doc """
  The human conversation contract from the published image (delegate for the spawner's Assets rail
  — `{:ok, content}` | `:unpublished` → caller's disk fallback). Added to a pod whose cap-profile
  declares `interlocutor: both`, served alone on `interlocutor: human`.
  """
  defdelegate image_human_protocol(), to: Fleet.SPBuilder.Image, as: :human_protocol

  @doc """
  Sources whose content no longer matches what the published image validated (delegate —
  `{:ok, [{path, :modified | :vanished}]}` | `:unpublished`). Consulted on the spawn path so a
  deployed program edited under a live daemon stops being a non-event.
  """
  defdelegate image_drift(), to: Fleet.SPBuilder.Image, as: :drift

  @doc """
  Compose the system prompt from a cap-profile and modop bundles.

  ## Inputs

    * `cap_profile` — `%Fleet.CapProfile{}` struct from `Fleet.CapProfile.compose/2`
    * `modop_bundles` — ordered list of modop names (order = precedence)
    * `opts`:
      * `:pod_id` (volatile, excluded from the stable sha256)
      * `:job_id` (volatile)
      * `:attempt_id` (volatile)
      * `:spawned_at` (volatile, DateTime, default `DateTime.utc_now/0`)
      * `:preloaded_paths` (archive-mode paths, **included** in the stable hash)
      * `:brief_path` (referenced by path, not composed into the SP)

  ## Exit codes

    * `{:ok, %{sp_md, stable_sha256, metadata}}` — composition OK
    * `{:error, {:modop_bundle_missing, name}}` — modop sp.md absent
    * `{:error, {:sp_role_path_missing, path}}` — SP role base absent
    * `{:error, {:template_render_failed, reason}}` — EEx error
  """
  @impl Fleet.SPBuilder.Composer
  @spec compose(Fleet.CapProfile.t(), [String.t()], compose_opts()) ::
          {:ok, composed()} | {:error, term()}
  def compose(%Fleet.CapProfile{} = cap_profile, modop_bundles, opts \\ [])
      when is_list(modop_bundles) and is_list(opts) do
    with :ok <- validate_compose_opts(opts),
         {:ok, sp_role_base} <- read_sp_role_base(cap_profile),
         {:ok, modop_fragments} <- read_modop_fragments(modop_bundles),
         {:ok, subagent_fragment} <- read_subagent_template(cap_profile),
         {:ok, monk_inj} <- Monk.resolve_or_empty(cap_profile, opts) do
      preloaded_paths =
        Keyword.get(opts, :preloaded_paths, []) ++ monk_inj.corpus_paths

      # The cap-profile's `invocation.subagent_template` fragment (e.g. reviewer →
      # code-quality-reviewer, qualifier → spec-reviewer) is injected here, next to the modop
      # fragments (both are SP overlays keyed on the cap-profile).
      modop_concat =
        modop_fragments_concat(modop_fragments) <>
          subagent_fragment <> Monk.persona_section(monk_inj)

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
  Compose the pod's `CLAUDE.md` (N3) — pod conventions + selective extraction
  of the repo `CLAUDE.md` sections if provided.

  Sections extracted from the repo CLAUDE.md (if provided): `Stack`, `Build`,
  `Test`, `Conventions`, `Commands`, `Gotchas` — each level-2 header
  and its body up to the next header.

  ## Exit codes

    * `{:ok, claude_md_content}` — composition OK
    * `{:error, {:repo_claude_md_unreadable, path, reason}}` — path given but unreadable
    * `{:error, {:template_render_failed, reason}}` — EEx error
  """
  @impl Fleet.SPBuilder.Composer
  @spec compose_claude_md(Fleet.CapProfile.t(), String.t() | nil, keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def compose_claude_md(%Fleet.CapProfile{} = cap_profile, repo_claude_md_path, _opts \\ []) do
    with {:ok, repo_sections} <- RepoSections.read(repo_claude_md_path) do
      assigns = [
        role: Fleet.CapProfile.name(cap_profile),
        containment: Fleet.CapProfile.containment(cap_profile),
        # lifetime_scope is nested under spec.invocation (schema v2.5 +
        # canon cap-profiles; consistent with check_lifetime_scope/1). The old
        # spec.lifetime_scope path (pre-v2.5) always yields "unknown".
        lifetime_scope: Fleet.CapProfile.lifetime_scope(cap_profile, "unknown"),
        git_ops_denied: get_in(cap_profile.spec, ["scope", "git_ops_denied"]) || [],
        repo_claude_md_sections: repo_sections
      ]

      render_template(:claude_md, assigns)
    end
  end

  @doc """
  Filters `skills_root` by the `cap_profile.spec["knowledge"]["skills"]` whitelist.

  Returns the list of absolute paths to mount-bind into the pod. A PLAIN
  whitelisted skill absent from the FS is a **fail-loud** (no silent
  filtering — a pod must not claim a nonexistent skill). QUALIFIED
  `plugin:skill` skills are delivered via `LCARS_SKILLS_PLUGINS` (not as
  paths) → excluded from this presence check.

  ## Exit codes

    * `{:ok, [absolute_path, ...]}` — paths of the present plain skills (order preserved)
    * `{:error, {:skills_missing, [name, ...]}}` — whitelisted plain skill(s) absent
    * `{:error, :skills_root_missing}` — `skills_root` does not exist
  """
  @impl Fleet.SPBuilder.Composer
  @spec filter_skills(Fleet.CapProfile.t(), Path.t()) :: {:ok, [Path.t()]} | {:error, term()}
  def filter_skills(%Fleet.CapProfile{} = cap_profile, skills_root)
      when is_binary(skills_root) do
    if File.dir?(skills_root) do
      whitelist = get_in(cap_profile.spec, ["knowledge", "skills"]) || []

      # QUALIFIED `plugin:skill` skills are delivered via
      # `LCARS_SKILLS_PLUGINS` (skills_plugins_env → bwrap loads the plugin),
      # NOT as mounted paths → excluded from the on-disk presence check.
      plain = Enum.reject(whitelist, &String.contains?(&1, ":"))

      # Each plain skill name becomes a bind-mount SOURCE in the pod: a name that is not a plain slug
      # (`..`, `/`, absolute, control) could probe/mount an arbitrary path (R1-29). Refuse fail-loud rather
      # than resolve it (skill dirs are slugs; a `plugin:skill` was already excluded above).
      case Enum.reject(plain, &Fleet.Slug.valid?/1) do
        [] ->
          {present, missing} =
            plain
            |> Enum.map(&{&1, Path.join(skills_root, &1)})
            |> Enum.split_with(fn {_name, path} -> File.exists?(path) end)

          # A whitelisted skill ABSENT from disk is a fail-loud (an upstream error
          # that makes the "missing skill" state unrepresentable, not caught downstream):
          # `{:error, {:skills_missing, names}}`, not a silent filtering of the pod.
          case missing do
            [] -> {:ok, Enum.map(present, fn {_name, path} -> path end)}
            _ -> {:error, {:skills_missing, Enum.map(missing, fn {name, _path} -> name end)}}
          end

        unsafe ->
          {:error, {:skills_unsafe, unsafe}}
      end
    else
      {:error, :skills_root_missing}
    end
  end

  @doc """
  Resolves the cap-profile's monk injection — historical public API, delegated to
  `Fleet.SPBuilder.Monk.resolve/2` (detailed contract, options and error codes
  documented over there). `{:ok, %{persona_hint, corpus_paths}}` | `:not_a_monk` |
  `{:error, term()}`.
  """
  @spec resolve_monk_injection(Fleet.CapProfile.t(), keyword()) ::
          {:ok, Monk.injection()} | :not_a_monk | {:error, term()}
  defdelegate resolve_monk_injection(cap_profile, opts \\ []), to: Monk, as: :resolve

  # Parse-at-boundary: the load-bearing opts CRASH the composition if malformed — a `preloaded_paths`
  # that is not a list of binaries blows up the `++` / concat, a `spawned_at` that is not a `%DateTime{}`
  # blows up `DateTime.to_iso8601`. Turn those into a typed `{:error, {:bad_opt, _}}` (compose promises
  # `{:ok}|{:error}`), never a raise. Prod callers (`Pod`) pass the defaults; this guards a direct caller.
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

  # ============================================================
  # SP role base + modop fragments I/O
  # ============================================================

  defp read_sp_role_base(%Fleet.CapProfile{spec: spec}) do
    case get_in(spec, ["systemPrompt"]) do
      nil ->
        {:ok, ""}

      path when is_binary(path) ->
        root = sp_role_root()
        full_path = Path.join(root, path)

        # `systemPrompt` comes from the catalogue YAML (untrusted artifact): confine the read to the SP
        # root (R1-01). A control char (incl. NUL — which would raise in Path.expand/File.read) is refused
        # first, then the joined path must stay UNDER the root (`..` traversal → escape → refused).
        cond do
          String.match?(path, ~r/[\x00-\x1F\x7F]/) ->
            {:error, {:sp_role_path_unsafe, path}}

          not Fleet.Slug.under_root?(full_path, root) ->
            {:error, {:sp_role_path_escape, path}}

          true ->
            # Image FIRST (proven-good epoch): the path is validated above, then resolved against the
            # frozen snapshot. `:not_found` under a published image is a CLOSED WORLD verdict — the
            # catalogue names a base this deploy does not ship — and must NOT fall back to disk, or
            # the epoch reopens exactly where it matters. Only `:unpublished` (tests, tooling) reads
            # the live file.
            case Fleet.SPBuilder.Image.sp_role_base(path) do
              {:ok, content} -> {:ok, content}
              :not_found -> {:error, {:sp_role_path_missing, full_path}}
              :unpublished -> read_sp_role_base_from_disk(full_path)
            end
        end
    end
  end

  defp read_sp_role_base_from_disk(full_path) do
    case File.read(full_path) do
      {:ok, content} -> {:ok, content}
      {:error, _reason} -> {:error, {:sp_role_path_missing, full_path}}
    end
  end

  # No modop requested → nothing to read (this `[]` clause). A role with NO default modops takes it; a
  # role WITH modops (consultant/starfleet) goes through the clause below, where `modop_root` IS resolved
  # and IS wired into the spawn chain (cf. pod.ex `compose(cap, active_modops(cap), …)`).
  defp read_modop_fragments([]), do: {:ok, []}

  # IMAGE-FIRST (proven-good image at boot, sp_builder half): a published image carries every
  # bundle fragment — a name absent from it is `:modop_bundle_missing` (closed world; a
  # traversal-shaped name simply misses the map). No image → live-disk fallback below, unchanged.
  defp read_modop_fragments(modop_bundles) do
    case Fleet.SPBuilder.Image.published() do
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
    root = modop_root()

    result =
      Enum.reduce_while(modop_bundles, {:ok, []}, fn name, {:ok, acc} ->
        # Confine the modop leaf under `root`: a malformed `name` (`..`, `/`, absolute) never reaches
        # the FS (R1-02/03) — same patron as `Fleet.CapProfile.Catalog.read_modops`.
        case Fleet.Slug.confined_join(root, name) do
          {:ok, dir} ->
            case File.read(Path.join(dir, "sp.md")) do
              {:ok, content} -> {:cont, {:ok, [{name, content} | acc]}}
              {:error, _reason} -> {:halt, {:error, {:modop_bundle_missing, name}}}
            end

          {:error, reason} ->
            {:halt, {:error, {:modop_bundle_unsafe, {name, reason}}}}
        end
      end)

    case result do
      {:ok, fragments} -> {:ok, Enum.reverse(fragments)}
      error -> error
    end
  end

  # Reads the SINGLE `subagent_template` SP fragment the cap-profile declares
  # (`invocation.subagent_template` → `subagent-<name>.md`). Pattern-match (no `get_in`) so a malformed
  # `invocation` never crashes the spawn. Non-null → the fragment (prefixed with a newline for separation);
  # null/absent → "". A DECLARED-but-missing/unsafe template → fail-loud (the pod does not launch on a
  # half-composed SP), same policy as a missing modop bundle.
  defp read_subagent_template(%Fleet.CapProfile{
         spec: %{"invocation" => %{"subagent_template" => name}}
       })
       when is_binary(name) and name != "" do
    # `Slug.valid?` guards `name` as a safe slug (kebab, no `.`/`..`/`/`) — the question here is
    # ONLY "is the name safe as a path fragment?" (the real leaf is `subagent-<name>.md`, built
    # below); `valid?` states that intent directly (same gesture as filter_skills).
    if Fleet.Slug.valid?(name) do
      # IMAGE-FIRST (same closed world as the modop fragments); no image → live disk.
      case fetch_subagent_content(name) do
        {:ok, content} -> {:ok, "\n<!-- subagent-template:#{name} -->\n" <> content}
        :error -> {:error, {:subagent_template_missing, name}}
      end
    else
      {:error, {:subagent_template_unsafe, name}}
    end
  end

  defp read_subagent_template(_cap_profile), do: {:ok, ""}

  defp fetch_subagent_content(name) do
    case Fleet.SPBuilder.Image.published() do
      %{subagent: templates} ->
        Map.fetch(templates, name)

      nil ->
        case File.read(Path.join(subagent_template_root(), "subagent-#{name}.md")) do
          {:ok, content} -> {:ok, content}
          {:error, _} -> :error
        end
    end
  end

  defp subagent_template_root do
    Application.get_env(:fleet_sp_builder, :subagent_template_root) ||
      Application.app_dir(:lcars_fleet, "priv/cap_profile/canon/subagent-templates")
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

  defp render_template(:sp, assigns), do: do_render("sp_template.eex", assigns)
  defp render_template(:claude_md, assigns), do: do_render("claude_md_template.eex", assigns)

  # A template is the SHAPE of every prompt the fleet emits — imaged like the rest, and rendered from
  # the frozen SOURCE (`eval_string`) so no spawn ever re-reads the file. `:not_found` under a
  # published image is a closed-world error, never a silent disk fallback; `:unpublished` (tests,
  # tooling) renders from the live file, unchanged.
  defp do_render(name, assigns) do
    case Fleet.SPBuilder.Image.template(name) do
      {:ok, source} -> {:ok, EEx.eval_string(source, assigns: assigns)}
      :not_found -> {:error, {:template_missing_from_image, name}}
      :unpublished -> {:ok, EEx.eval_file(template_path(name), assigns: assigns)}
    end
  rescue
    e -> {:error, {:template_render_failed, Exception.message(e)}}
  end

  defp template_path(name) do
    Path.join([to_string(:code.priv_dir(:lcars_fleet)), "sp_builder/templates", name])
  end

  # ============================================================
  # Path resolution (config knobs for testability)
  # ============================================================

  # `sp_role_root` — base under which a cap-profile's `spec.systemPrompt` path resolves. Default =
  # the BUNDLED cap-profiles canon (`Application.app_dir(:lcars_fleet, "priv/cap_profile/…")`, the
  # SAME source as `Fleet.CapProfile.root_dir/0`'s DEFAULT — true of the defaults ONLY:
  # `LCARS_CAPPROFILES_ROOT` repoints the YAML catalogue (`:fleet_cap_profile, :root_dir`) but NOT
  # this root nor its siblings (modop, subagent_template, monk_registry), which stay on the bundled
  # priv) → resolves in RELEASE as in dev WITHOUT env (a CWD-relative default would not).
  # Config override (test).
  defp sp_role_root do
    Application.get_env(:fleet_sp_builder, :sp_role_root) ||
      Application.app_dir(:lcars_fleet, "priv/cap_profile/canon/cap-profiles")
  end

  # `modop_root` — base of the modop SP fragments (`<root>/<name>/sp.md`). Config-overridable, with a
  # BUNDLED DEFAULT = `Application.app_dir(:lcars_fleet, "priv/cap_profile/canon/modop-bundles")` — the
  # SAME source as `sp_role_root` (the modop-bundles canon is co-located with the cap-profiles
  # under the cap_profile priv, F-C146). The prod spawn chain passes the cap-profile's
  # `modop_set.default` (`compose(cap, modops, …)`) → this root IS required and resolves.
  defp modop_root do
    Application.get_env(:fleet_sp_builder, :modop_root) ||
      Application.app_dir(:lcars_fleet, "priv/cap_profile/canon/modop-bundles")
  end
end
