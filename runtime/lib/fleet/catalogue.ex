defmodule Fleet.Catalogue do
  use Boundary, deps: [], exports: []

  @moduledoc """
  Resolves catalogue locations, tree scopes and manifest identity without domain dependencies.

  Project readers use `tree_scope/2` and `find_in/2`: their catalogue, then system defaults.
  `search/1` is a global view over installed catalogues; it must not choose a neighbour's
  role or prompt for a project. `root/0` selects the default catalogue when none is named.
  A whole-root override keeps related trees together; fine overrides replace one business
  tree while retaining system fallback, allowing deliberate mixed sources and test isolation.

  Catalogue roots contain replaceable/exportable material, including build-time SP blocks.
  Runtime schemas, the git-denial baseline and frozen Memory-X assets stay outside them:
  exporting editable copies of runtime contracts would suggest controls that have no effect.

  The required catalogue.yaml manifest supplies a stable name (forge organisation and role-login
  prefix) and artifact compatibility version. File schemas remain chosen by code; a manifest
  version does not reintroduce per-profile apiVersion. `verify!/0` checks the current root's
  manifest, name and default-card declaration before callers publish its images.
  """

  require Logger

  @manifest_basename "catalogue.yaml"

  # A list permits compatibility across generations during an ordered upgrade.
  @supported_api_versions [1]

  # Stricter than path slugs: '_' separates <catalogue>_<role> logins and cannot occur in a name.
  @name_rx ~r/\A[a-z0-9][a-z0-9-]*\z/

  @rel_cap_profiles "cap_profile/cap-profiles"
  @rel_modops "cap_profile/modop-bundles"
  @rel_subagent_templates "cap_profile/subagent-templates"
  @rel_monk_registry "cap_profile/cap-profiles/monks"
  @rel_sp_drafts "sp_builder/sp_drafts"
  @rel_sp_blocks "sp_builder/sp_blocks"
  @rel_sp_templates "sp_builder/templates"
  @rel_workflow_maps "workflow/workflow_maps"
  @rel_brief_templates "workflow/brief_templates"
  @rel_project_template "project_template"
  @rel_skills "skills"

  # Optional role-named avatars avoid a separate account-to-image roster; absence keeps identicons.
  @rel_avatars "avatars"

  @doc """
  Returns the default catalogue root: :catalogue_root (configured from LCARS_CATALOGUE_ROOT),
  or release-relative priv/catalogue. Explicit nil uses that default too.
  This is also the first installed_roots entry; use root/0 to express default resolution.
  """
  @spec root() :: Path.t()
  def root, do: to_string(bundled_root())

  defp bundled_root do
    Application.get_env(:lcars_fleet, :catalogue_root) ||
      Application.app_dir(:lcars_fleet, "priv/catalogue")
  end

  @doc """
  Returns release-relative priv/catalogue-system, or :catalogue_system_root when configured.
  That application-env override is a test seam, with no dedicated runtime environment-variable
  setting; it is not access-controlled here. System supplies mechanism defaults, which business
  entries may shadow by name/path through the search functions.
  """
  @spec system_root() :: Path.t()
  def system_root do
    Application.get_env(:lcars_fleet, :catalogue_system_root) ||
      Application.app_dir(:lcars_fleet, "priv/catalogue-system")
  end

  @doc """
  Returns existing directories in precedence order: explicit business tree, then system/rel.
  The caller resolves business overrides. A business file shadows the same system path;
  missing trees are omitted so catalogues need only ship the material they use.
  """
  @spec search(Path.t(), String.t()) :: [Path.t()]
  def search(business, rel) when is_binary(business) and is_binary(rel) do
    Enum.filter([business, Path.join(system_root(), rel)], &File.dir?/1)
  end

  # Replace the business list, not prepend: fixtures must not inherit bundled business data.
  # Keep system fallback. Trees absent from this map have no fine override.
  @fine_overrides %{
    cap_profiles: {:lcars_fleet, :cap_profile_root_dir},
    modops: {:lcars_fleet, :sp_builder_modop_root},
    subagent_templates: {:lcars_fleet, :sp_builder_subagent_template_root},
    sp_drafts: {:lcars_fleet, :sp_builder_sp_drafts_root}
  }

  @doc """
  Returns the global tree search path: fine override or all installed business trees,
  followed by system, deduplicated and filtered to existing directories.
  Use tree_scope/2 for project-specific resolution instead of merging neighbouring catalogues.
  """
  @spec search(atom()) :: [Path.t()]
  def search(tree) when is_atom(tree) do
    rel = rel(tree)

    case fine_override(tree) do
      nil -> Enum.map(installed_roots(), &Path.join(&1, rel))
      dir -> [dir]
    end
    |> Kernel.++([Path.join(system_root(), rel)])
    |> Enum.uniq()
    |> Enum.filter(&File.dir?/1)
  end

  # Forge organisation of this catalogue's projects. The system org (`lcars`, PROV_FORGE_ORG_DEFAULT)
  # is distinct: it carries identity and the system repositories, never a project.
  @bundled_name "fleet"

  @doc """
  Returns the bundled catalogue's reserved name. CatalogueLifecycle uses it to keep forge
  installations/deposits from replacing the release-owned catalogue.
  """
  @spec bundled_name() :: String.t()
  def bundled_name, do: @bundled_name

  @doc """
  Returns root/0 first (normally `#{@bundled_name}`), then discovered installation directories
  ordered by basename. Discovery requires a catalogue.yaml path, skips basename `#{@bundled_name}`
  and keeps the first directory for duplicate basenames. It does not validate manifests or
  check the unconditional default root's existence. System is added separately by scope readers.

  Installed material, not a second active-list declaration, controls discovery. Provisioning
  supplies this cache from forge catalogue stores; deleting local material is not an uninstall
  and convergence may restore it. A separate active list could omit installed projects or activate
  roles without provisioned accounts. Project scopes still keep neighbouring catalogues separate.
  """
  @spec installed_roots() :: [Path.t()]
  def installed_roots do
    [root() | installed_dirs()]
  end

  # Runtime config supplies Layout's paths so this foundation module keeps deps: [].
  # No configured directories means default catalogue only. Do not derive them via
  # System.user_home!/0: its cached value ignores tests moving HOME and could read real user data.
  defp install_dirs, do: Application.get_env(:lcars_fleet, :catalogue_install_dirs, [])

  # Requiring a manifest path avoids treating arbitrary cache directories as installations.
  defp installed_dirs do
    install_dirs()
    |> Enum.flat_map(fn dir -> Path.wildcard(Path.join(dir, "*/#{@manifest_basename}")) end)
    |> Enum.map(&Path.dirname/1)
    |> Enum.reject(&(Path.basename(&1) == @bundled_name))
    |> Enum.uniq_by(&Path.basename/1)
    |> Enum.sort_by(&Path.basename/1)
  end

  defp fine_override(tree) do
    case Map.get(@fine_overrides, tree) do
      nil -> nil
      {app, key} -> Application.get_env(app, key)
    end
  end

  @doc """
  Returns existing installed roots followed by system, for attribution across related trees.
  Fine tree overrides are not reflected here: callers must not assume those overridden trees
  remain under the corresponding root or zip independently filtered tree lists together.
  """
  @spec roots() :: [Path.t()]
  def roots, do: Enum.filter(installed_roots() ++ [system_root()], &File.dir?/1)

  @doc """
  Returns the first regular file at name on search/2, or the expected business path if missing,
  so a caller's enoent identifies the file its author should create. Does not confine name.
  """
  @spec find(Path.t(), String.t(), String.t()) :: Path.t()
  def find(business, rel, name) when is_binary(name) do
    paths = Enum.map(search(business, rel), &Path.join(&1, name))
    Enum.find(paths, Path.join(business, name), &File.regular?/1)
  end

  @doc "Relative path of a shared tree inside a catalogue — the ONE literal each, for `search/2`."
  @spec rel(atom()) :: String.t()
  def rel(:avatars), do: @rel_avatars
  def rel(:cap_profiles), do: @rel_cap_profiles
  def rel(:modops), do: @rel_modops
  def rel(:subagent_templates), do: @rel_subagent_templates
  def rel(:sp_drafts), do: @rel_sp_drafts
  def rel(:sp_blocks), do: @rel_sp_blocks
  def rel(:sp_templates), do: @rel_sp_templates
  def rel(:skills), do: @rel_skills

  # Cards and project templates need explicit-root addressing without cross-catalogue merging.
  def rel(:workflow_maps), do: @rel_workflow_maps
  # brief_templates still has no rel/1 clause: its reader uses the default root, leaving
  # per-catalogue brief-template selection unresolved.
  def rel(:project_template), do: @rel_project_template

  @doc """
  Returns default-catalogue SP blocks (`<root>/#{@rel_sp_blocks}`). The build-time composer
  resolves system defaults through search/2 and emits the drafts consumed by pods.
  """
  @spec sp_blocks_root() :: Path.t()
  def sp_blocks_root, do: Path.join(root(), @rel_sp_blocks)

  @doc "Cap-profile YAMLs, BUSINESS root (`<root>/#{@rel_cap_profiles}`) — the search path is `search/2`."
  @spec cap_profiles_root() :: Path.t()
  def cap_profiles_root, do: Path.join(root(), @rel_cap_profiles)

  @doc "Modop SP fragments, `<root>/#{@rel_modops}/<name>/sp.md`."
  @spec modop_root() :: Path.t()
  def modop_root, do: Path.join(root(), @rel_modops)

  @doc "Subagent templates (`<root>/#{@rel_subagent_templates}/subagent-<name>.md`)."
  @spec subagent_templates_root() :: Path.t()
  def subagent_templates_root, do: Path.join(root(), @rel_subagent_templates)

  @doc """
  Returns the monk registry tree. It always follows the catalogue root, not a
  cap-profile-specific override.
  """
  @spec monk_registry_root() :: Path.t()
  def monk_registry_root, do: Path.join(root(), @rel_monk_registry)

  @doc "Generated role drafts (`<root>/#{@rel_sp_drafts}/agent-<role>-base.md`)."
  @spec sp_drafts_root() :: Path.t()
  def sp_drafts_root, do: Path.join(root(), @rel_sp_drafts)

  @doc "EEx templates giving every emitted prompt its shape (`<root>/#{@rel_sp_templates}`)."
  @spec sp_templates_root() :: Path.t()
  def sp_templates_root, do: Path.join(root(), @rel_sp_templates)

  @doc """
  Returns one existing-directory search path per installed catalogue: own tree then system.
  A fine override replaces the installed list with one scope over system; empty scopes drop out.
  These filtered lists are not a cross-tree index: use tree_scope/2 when retaining root identity.
  """
  @spec scopes(atom()) :: [[Path.t()]]
  def scopes(tree) when is_atom(tree) do
    rel = rel(tree)
    sys = Path.join(system_root(), rel)

    case fine_override(tree) do
      nil -> Enum.map(installed_roots(), &Path.join(&1, rel))
      dir -> [dir]
    end
    |> Enum.uniq()
    |> Enum.map(fn dir -> Enum.filter([dir, sys], &File.dir?/1) end)
    |> Enum.reject(&(&1 == []))
  end

  @doc """
  Returns existing directories for one catalogue/tree: fine override or own tree, then system.
  Root identity makes this suitable for images spanning several trees. A fine override applies
  to every root passed, so several catalogues can share that overridden directory.
  """
  @spec tree_scope(Path.t(), atom()) :: [Path.t()]
  def tree_scope(root, tree) when is_binary(root) and is_atom(tree) do
    rel = rel(tree)
    own = fine_override(tree) || Path.join(root, rel)
    Enum.filter([own, Path.join(system_root(), rel)], &File.dir?/1)
  end

  @doc "Returns the first regular file at name in the explicit scope, or nil; no config or confinement."
  @spec find_in([Path.t()], String.t()) :: Path.t() | nil
  def find_in(scope, name) when is_list(scope) and is_binary(name) do
    Enum.find_value(scope, fn dir ->
      path = Path.join(dir, name)
      if File.regular?(path), do: path
    end)
  end

  @doc """
  Returns existing installed workflow-map directories in installed_roots order, without system.
  Publish one card image per directory: merging cards across catalogues could resolve their roles
  against another catalogue's definitions.
  """
  @spec workflow_maps_roots() :: [Path.t()]
  def workflow_maps_roots do
    installed_roots()
    |> Enum.map(&Path.join(&1, @rel_workflow_maps))
    |> Enum.uniq()
    |> Enum.filter(&File.dir?/1)
  end

  @doc "Workflow-map YAMLs (`<root>/#{@rel_workflow_maps}`)."
  @spec workflow_maps_root() :: Path.t()
  def workflow_maps_root, do: Path.join(root(), @rel_workflow_maps)

  @doc "Brief templates rendered into forge tickets (`<root>/#{@rel_brief_templates}`)."
  @spec brief_templates_root() :: Path.t()
  def brief_templates_root, do: Path.join(root(), @rel_brief_templates)

  @doc "Scaffolding copied into a freshly onboarded project (`<root>/#{@rel_project_template}/<face>`)."
  @spec project_template_root() :: Path.t()
  def project_template_root, do: Path.join(root(), @rel_project_template)

  # The system org carries the fleet's identity and the system's own repositories, never a
  # project. The machine names it (`LCARS_FORGE_ORG`, carried into config by `runtime.exs`); this
  # default is the same literal as the shell protocol's, and MUR 19 holds the readers equal.
  @system_org_default "lcars"

  @doc """
  Returns the system organisation: what the installer chose, `#{@system_org_default}` otherwise.
  """
  @spec system_org() :: String.t()
  def system_org,
    do: Application.get_env(:lcars_fleet, :catalogue_system_org, @system_org_default)

  # One repository for every installed catalogue, one branch each (⚖ user 2026-09-16). What is
  # installed is then ONE question to the forge — the branches of this repository — instead of a
  # search across every visible repository, and a catalogue's org carries its projects only.
  @store_name "_catalogues"

  @doc """
  Returns the repository that holds every installed catalogue's source, one branch per catalogue.

  A store is a BRANCH of this repository, named after the catalogue (`store_branch/1`), and its
  identity is still proven by the manifest read at that branch — a branch named `x` whose
  `catalogue.yaml` declares something else is not the store of `x`.

  Shell STORE_REPO declarations mirror the repository name (forge-gestures.sh and
  forge.d/catalogues.sh). Keep writers and convergence aligned: a wrong lookup can make present
  material appear absent and trigger removal. CatalogueStoreAddressTest checks the declarations.
  """
  @spec store_repo() :: String.t()
  def store_repo, do: "#{system_org()}/#{@store_name}"

  @doc "Returns the store repository's name, without its organisation."
  @spec store_name() :: String.t()
  def store_name, do: @store_name

  @doc "Returns the branch that holds `name`'s source inside the store repository."
  @spec store_branch(String.t()) :: String.t()
  def store_branch(name) when is_binary(name), do: name

  @doc """
  Returns the manifest basename for forge readers; manifest_path/0 joins it to the disk root.
  """
  @spec manifest_file() :: String.t()
  def manifest_file, do: @manifest_basename

  @doc """
  Extracts the first matching column-zero name line, or {:error, :no_name_in_manifest}.
  Shared by deposit listing and onboarding; shell readers mirror this rule.

  This is a regex extractor, not YAML parsing or name validation: optional double quotes and
  trailing comments are recognised, but YAML quoting/document/duplicate-key semantics are not.
  Unrelated malformed sections need not prevent identity listing; verify!/0 checks the artifact.
  Column-zero anchoring avoids stealing a nested name. Keep the optional comment capture in
  mind: matching [_, name] alone would reject lines with trailing comments.
  """
  @spec manifest_name(String.t()) :: {:ok, String.t()} | {:error, :no_name_in_manifest}
  def manifest_name(yaml) when is_binary(yaml) do
    yaml
    |> String.split("\n")
    |> Enum.find_value(fn line ->
      case Regex.run(~r/\Aname:\s*"?([^"#\s]+)"?\s*(#.*)?\z/, line) do
        [_, name | _] -> name
        _ -> nil
      end
    end)
    |> case do
      nil -> {:error, :no_name_in_manifest}
      name -> {:ok, name}
    end
  end

  @doc """
  Pod-mountable skills (`<root>/#{@rel_skills}/<name>/SKILL.md`) — filtered per cap-profile
  (`knowledge.skills` whitelist, `SPBuilder.filter_skills/2`) and bind-mounted RO into the pod's
  `~/.claude/skills/` (BL-6-22). The fine override is `:lcars_fleet, :spawner_skills_root`
  (`LCARS_SKILLS_ROOT`), resolved at SPAWN time — cf. the `:catalogue` sentinel in `Spawner.Pod`.
  """
  @spec skills_root() :: Path.t()
  def skills_root, do: Path.join(root(), @rel_skills)

  @doc "Path of the manifest (`<root>/#{@manifest_basename}`)."
  @spec manifest_path() :: Path.t()
  def manifest_path, do: Path.join(root(), @manifest_basename)

  @doc "Catalogue contract versions this runtime can consume."
  @spec supported_api_versions() :: [pos_integer()]
  def supported_api_versions, do: @supported_api_versions

  @doc """
  Checks that the current root is a directory and its manifest is a mapping with a supported
  version, valid name and default_card naming an own card when cards are present. Returns the
  manifest; failures raise operator-facing diagnostics. Card filenames are checked, not contents;
  other installed roots and catalogue assets are not validated by this call.
  """
  @spec verify!() :: map()
  def verify! do
    root = root()
    path = manifest_path()

    unless File.dir?(root) do
      raise """
      LCARS catalogue: root #{inspect(root)} is not a readable directory — boot refused.
      Set LCARS_CATALOGUE_ROOT to an unpacked catalogue, or unset it for the bundled one.
      """
    end

    manifest = read_manifest!(path)

    case Map.get(manifest, "api_version") do
      version when version in @supported_api_versions ->
        name = validate_name!(manifest, path)
        card = validate_default_card!(manifest, path, root)

        Logger.info(
          "Catalogue: verified (root=#{root}, name=#{name}, api_version=#{version}" <>
            if(card, do: ", default_card=#{card}", else: "") <> ")"
        )

        manifest

      other ->
        raise """
        LCARS catalogue: #{path} declares api_version #{inspect(other)}, this runtime consumes \
        #{inspect(@supported_api_versions)} — boot refused.
        The catalogue and the runtime are from incompatible generations; upgrade one of them.
        """
    end
  end

  # Never derive external identity from a local installation directory.
  defp validate_name!(manifest, path) do
    case Map.get(manifest, "name") do
      name when is_binary(name) ->
        if Regex.match?(@name_rx, name) do
          name
        else
          raise """
          LCARS catalogue: #{path} declares name #{inspect(name)} — boot refused.
          A catalogue name is kebab-case (#{inspect(Regex.source(@name_rx))}): lowercase, digits and \
          dashes, starting on a letter or a digit. `_` is refused on purpose — it separates the two \
          halves of a role account login (<catalogue>_<role>).
          """
        end

      nil ->
        raise """
        LCARS catalogue: #{path} declares no `name` — boot refused.
        The name is a property of the catalogue, not of where it was installed: it addresses the \
        catalogue outside this container (the forge org carrying its projects), so it cannot be the \
        directory someone happened to unpack it into.
        """

      other ->
        raise "LCARS catalogue: #{path} declares a non-string name (#{inspect(other)}) — boot refused."
    end
  end

  # Defaults are catalogue choices, not a runtime card literal. Require one when cards exist;
  # check filenames here to keep this foundation independent of the workflow loader.
  defp validate_default_card!(manifest, path, root) do
    cards =
      root
      |> Path.join(@rel_workflow_maps)
      |> Path.join("*.yaml")
      |> Path.wildcard()
      |> Enum.map(&Path.basename(&1, ".yaml"))

    case {Map.get(manifest, "default_card"), cards} do
      {nil, []} ->
        nil

      {nil, _} ->
        raise "LCARS catalogue: #{path} ships #{length(cards)} card(s) and declares no " <>
                "`default_card` — boot refused. A project that declares no card takes the " <>
                "catalogue's default, and no property distinguishes one card from another: it " <>
                "has to be said. One of #{inspect(Enum.sort(cards))}."

      {card, _} when is_binary(card) ->
        if card in cards do
          card
        else
          raise "LCARS catalogue: #{path} declares default_card #{inspect(card)}, which is " <>
                  "not one of its own cards — boot refused. It ships #{inspect(Enum.sort(cards))}."
        end

      {other, _} ->
        raise "LCARS catalogue: #{path} declares a non-string default_card (#{inspect(other)}) — boot refused."
    end
  end

  @doc """
  Reads the current manifest's string name, or nil on missing/non-string/unreadable data.
  No cache or syntax validation here; verify!/0 validates the name used for forge identity.
  """
  @spec name() :: String.t() | nil
  def name do
    case YamlElixir.read_from_file(manifest_path()) do
      {:ok, %{"name" => n}} when is_binary(n) -> n
      _ -> nil
    end
  end

  @doc """
  Returns unique names from installed_catalogues/0 in installation order, for forge discovery.
  Skipped or malformed manifests are not replaced with directory-derived identities.
  """
  @spec installed_names() :: [String.t()]
  def installed_names, do: installed_catalogues() |> Enum.map(& &1.name) |> Enum.uniq()

  @doc """
  Rereads installed manifests and returns %{name, root} for each string name, preserving root order.
  Unreadable manifests and missing/non-string names are skipped. Empty/invalid strings and duplicate
  declared names are not rejected here; this is identity projection, not verification.
  """
  @spec installed_catalogues() :: [%{name: String.t(), root: Path.t()}]
  def installed_catalogues do
    Enum.flat_map(installed_roots(), fn root ->
      case YamlElixir.read_from_file(Path.join(root, @manifest_basename)) do
        {:ok, %{"name" => n}} when is_binary(n) -> [%{name: n, root: root}]
        _ -> []
      end
    end)
  end

  @doc """
  Returns the first installed root with the exact declared name, or nil for nil/unknown names.
  Dispatch derives the name from a project's forge owner. Callers that interpret nil as default
  resolution must distinguish an unknown catalogue themselves if fallback is inappropriate.
  """
  @spec root_for(String.t() | nil) :: Path.t() | nil
  def root_for(nil), do: nil

  def root_for(name) when is_binary(name) do
    case Enum.find(installed_catalogues(), &(&1.name == name)) do
      %{root: root} -> root
      nil -> nil
    end
  end

  @doc """
  Resolves the segment before the first slash through root_for/1; non-strings return nil.
  Does not validate owner/name shape, so a bare owner or additional segments are accepted.
  """
  @spec root_for_repo(String.t() | nil) :: Path.t() | nil
  def root_for_repo(full_name) when is_binary(full_name) do
    full_name |> String.split("/") |> List.first() |> root_for()
  end

  def root_for_repo(_), do: nil

  @doc """
  Reads the default catalogue's declared default_card string, or nil on absent/invalid data.
  Does not check whether the card exists; verify!/0 performs that check.
  """
  @spec default_card() :: String.t() | nil
  def default_card, do: default_card(root())

  @doc """
  Reads default_card from the explicit root's manifest without caching or card validation.
  Returns any string (including empty), otherwise nil.
  """
  @spec default_card(Path.t()) :: String.t() | nil
  def default_card(root) when is_binary(root) do
    case YamlElixir.read_from_file(Path.join(root, @manifest_basename)) do
      {:ok, %{"default_card" => card}} when is_binary(card) -> card
      _ -> nil
    end
  end

  defp read_manifest!(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, %{} = manifest} ->
        manifest

      {:ok, other} ->
        raise "LCARS catalogue: #{path} is not a mapping (#{inspect(other)}) — boot refused."

      {:error, reason} ->
        raise """
        LCARS catalogue: #{path} unreadable (#{inspect(reason)}) — boot refused.
        A catalogue root without its manifest is a directory that merely looks like one.
        """
    end
  end
end
