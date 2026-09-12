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
      # RepoSections filters imported repository instructions.
      Fleet.ReceptionFilter
    ],
    exports: []

  @moduledoc """
  Composes `system-prompt.md`, pod `CLAUDE.md` and skill mount paths from a
  cap profile and catalogue artifacts. Reads published images or disk; EEx
  templates execute in the daemon. Monk and RepoSections own their respective
  injection and repository-section resolution.

  The launcher injects the composed prompt via `--system-prompt-file` from
  `.lcars/`, avoiding prompt content in argv and the credentials bind over
  `.claude/`. Brief content is referenced separately through `~/context/brief.md`.

  `stable_sha256` hashes resolved fragments and preloaded paths, excluding pod/job/
  attempt identifiers and timestamps. It does not hash the enclosing EEx template
  or the full rendered prompt; repeatability also requires unchanged artifact bytes.
  """

  @behaviour Fleet.SPBuilder.Composer

  alias Fleet.CapProfile
  alias Fleet.Catalogue
  alias Fleet.SPBuilder.Image
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
  @spec publish_image!() :: :ok
  defdelegate publish_image!(), to: Image, as: :publish!

  @doc "Returns a published role draft, `:not_found`, or `:unpublished`."
  @spec image_draft(String.t()) :: {:ok, String.t()} | :not_found | :unpublished
  defdelegate image_draft(role), to: Image, as: :draft
  @spec image_draft(String.t(), Path.t() | nil) :: {:ok, String.t()} | :not_found | :unpublished
  defdelegate image_draft(role, root), to: Image, as: :draft

  @doc "Returns the published worker protocol or `:unpublished`."
  @spec image_worker_protocol() :: {:ok, String.t()} | :unpublished
  defdelegate image_worker_protocol(), to: Image, as: :worker_protocol
  @spec image_worker_protocol(Path.t() | nil) :: {:ok, String.t()} | :unpublished
  defdelegate image_worker_protocol(root), to: Image, as: :worker_protocol

  @doc "Returns the published human protocol or `:unpublished`."
  @spec image_human_protocol() :: {:ok, String.t()} | :unpublished
  defdelegate image_human_protocol(), to: Image, as: :human_protocol
  @spec image_human_protocol(Path.t() | nil) :: {:ok, String.t()} | :unpublished
  defdelegate image_human_protocol(root), to: Image, as: :human_protocol

  @doc "Returns modified/vanished image sources, or `:unpublished`."
  @spec image_drift() :: {:ok, [{Path.t(), :modified | :vanished}]} | :unpublished
  defdelegate image_drift(), to: Image, as: :drift

  @doc """
  Composes a system prompt from a cap profile and ordered modop bundles.

  Preloaded paths affect `stable_sha256`; `pod_id`, `job_id`, `attempt_id` and
  `spawned_at` are volatile. Missing, unsafe or malformed inputs return typed
  errors for the checked cases; malformed keyword containers or cap profiles may raise.
  """
  @impl Fleet.SPBuilder.Composer
  @spec compose(CapProfile.t(), [String.t()], compose_opts()) ::
          {:ok, composed()} | {:error, term()}
  def compose(%CapProfile{} = cap_profile, modop_bundles, opts \\ [])
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
  @spec compose_claude_md(CapProfile.t(), String.t() | nil, keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def compose_claude_md(%CapProfile{} = cap_profile, repo_claude_md_path, _opts \\ []) do
    with {:ok, repo_sections} <- RepoSections.read(repo_claude_md_path) do
      assigns = [
        role: CapProfile.name(cap_profile),
        containment: CapProfile.containment(cap_profile),
        lifetime_scope: CapProfile.lifetime_scope(cap_profile, "unknown"),
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
  @spec filter_skills(CapProfile.t(), Path.t()) :: {:ok, [Path.t()]} | {:error, term()}
  def filter_skills(%CapProfile{} = cap_profile, skills_root)
      when is_binary(skills_root) do
    # Include system skills: a business role may depend on a skill shipped there.
    roots = Catalogue.search(skills_root, Catalogue.rel(:skills))

    if roots == [] do
      {:error, :skills_root_missing}
    else
      whitelist = get_in(cap_profile.spec, ["knowledge", "skills"]) || []
      plain = Enum.reject(whitelist, &String.contains?(&1, ":"))

      case Enum.reject(plain, &Fleet.Slug.valid?/1) do
        [] -> located_skills(plain, roots)
        unsafe -> {:error, {:skills_unsafe, unsafe}}
      end
    end
  end

  @doc """
  Resolves the cap profile's monk injection through `Fleet.SPBuilder.Monk`.
  """
  @spec resolve_monk_injection(CapProfile.t(), keyword()) ::
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

  defp sp_image(nil), do: Image.published()
  defp sp_image(root) when is_binary(root), do: Image.published(root)

  defp read_modop_fragments([], _root), do: {:ok, []}

  # Published fragments use the profile's root (nil selects the default image).
  # The disk fallback still uses global Catalogue.search/1, unlike subagent templates.
  defp read_modop_fragments(modop_bundles, root) do
    case sp_image(root) do
      %{modop_sp: fragments} ->
        Enum.reduce_while(modop_bundles, {:ok, []}, &fragment_step(&1, &2, fragments))
        |> case do
          {:ok, list} -> {:ok, Enum.reverse(list)}
          error -> error
        end

      nil ->
        read_modop_fragments_from_disk(modop_bundles)
    end
  end

  defp read_modop_fragments_from_disk(modop_bundles) do
    roots = Catalogue.search(:modops)

    result =
      Enum.reduce_while(modop_bundles, {:ok, []}, fn name, {:ok, acc} ->
        # Validate the path segment against each root tried; this is lexical confinement.
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

  defp read_subagent_template(
         %CapProfile{spec: %{"invocation" => %{"subagent_template" => name}}} = cap
       )
       when is_binary(name) and name != "" do
    if Fleet.Slug.valid?(name) do
      # Select the profile's image, not another catalogue's identically named template.
      case fetch_subagent_content(name, cap.catalogue_root) do
        {:ok, content} -> {:ok, "\n<!-- subagent-template:#{name} -->\n" <> content}
        :error -> {:error, {:subagent_template_missing, name}}
      end
    else
      {:error, {:subagent_template_unsafe, name}}
    end
  end

  defp read_subagent_template(_cap_profile), do: {:ok, ""}

  defp fetch_subagent_content(name, root) do
    case sp_image(root) do
      %{subagent: templates} ->
        Map.fetch(templates, name)

      nil ->
        # Match image precedence: this catalogue, then system; no other business catalogue.
        scope_root = root || Catalogue.root()

        Catalogue.tree_scope(scope_root, :subagent_templates)
        |> Catalogue.find_in("subagent-#{name}.md")
        |> read_or_error()
    end
  end

  # First existing path wins. Missing skills fail the whole request; existence does not
  # validate file type, readability or symlink confinement.
  defp located_skills(plain, roots) do
    plain
    |> Enum.map(fn name ->
      {name, Enum.find(Enum.map(roots, &Path.join(&1, name)), &File.exists?/1)}
    end)
    |> Enum.split_with(fn {_name, path} -> path != nil end)
    |> then(fn {present, missing} -> skills_verdict(present, missing) end)
  end

  defp skills_verdict(present, []), do: {:ok, Enum.map(present, fn {_name, path} -> path end)}

  defp skills_verdict(_present, missing),
    do: {:error, {:skills_missing, Enum.map(missing, fn {name, _path} -> name end)}}

  defp fragment_step(name, {:ok, acc}, fragments) do
    case Map.fetch(fragments, name) do
      {:ok, content} -> {:cont, {:ok, [{name, content} | acc]}}
      :error -> {:halt, {:error, {:modop_bundle_missing, name}}}
    end
  end

  defp read_or_error(nil), do: :error
  defp read_or_error(path), do: with({:error, _} <- File.read(path), do: :error)

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

  # EEx executes arbitrary Elixir with daemon rights: catalogue templates must be trusted.
  # Published bytes stay fixed until republished; an image miss never falls back to disk.
  # With no image, each render reads live disk. Boot normally publishes; the
  # boot.proven_image_regime contract checks the test-only configuration opt-out.
  # A source fingerprint is not a sandbox or a validation of the template's behaviour.
  defp do_render(name, assigns) do
    case Image.template(name) do
      {:ok, source} -> {:ok, EEx.eval_string(source, assigns: assigns)}
      :not_found -> {:error, {:template_missing_from_image, name}}
      :unpublished -> {:ok, EEx.eval_file(template_path(name), assigns: assigns)}
    end
  rescue
    e -> {:error, {:template_render_failed, Exception.message(e)}}
  end

  defp template_path(name), do: Path.join(Catalogue.sp_templates_root(), name)

  @doc """
  Returns the shared root used both to publish role drafts and to serve the
  unpublished disk fallback.
  """
  @spec sp_drafts_root() :: String.t()
  def sp_drafts_root do
    Application.get_env(:lcars_fleet, :sp_builder_sp_drafts_root) ||
      Catalogue.sp_drafts_root()
  end

  @doc """
  Finds a role draft on disk in `root`, then system, matching image scope.
  nil selects Catalogue.root/0. Avoid global search: duplicate role names must
  resolve within the caller's catalogue. If absent, returns that catalogue's
  expected path so the caller's file error identifies where to create the draft.
  The caller must supply a safe role name; this function does not validate it.
  """
  @spec sp_draft_path(String.t(), Path.t() | nil) :: Path.t()
  def sp_draft_path(role, root \\ nil) when is_binary(role) do
    scope_root = root || Catalogue.root()
    name = "agent-#{role}-base.md"

    scope = Catalogue.tree_scope(scope_root, :sp_drafts)

    case Catalogue.find_in(scope, name) do
      nil -> Path.join([scope_root, Catalogue.rel(:sp_drafts), name])
      path -> path
    end
  end
end
