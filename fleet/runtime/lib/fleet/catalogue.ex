defmodule Fleet.Catalogue do
  use Boundary, deps: [], exports: []

  @moduledoc """
  The single authority for WHERE the catalogue lives — one root, one sub-path per tree.

  ## Runtime vs catalogue

  The runtime is the machine that runs agents; the catalogue is the business it runs. The
  discriminator is mechanical and holds everywhere in `priv/`: `canon/`, `config/` and `templates/`
  hold the business material an operator legitimately replaces, and ONLY those resolve through this
  module. Everything else under `priv/` is runtime, resolved by `:code.priv_dir` with no knob —
  `schema/` (the contract a catalogue is validated against) and `baseline/` (a floor a catalogue may
  not lower, e.g. the universal git denylist). Both by the same rule: **what an operator must not be
  able to replace is a contract, and a contract an operator can swap does not constrain.**

  Corollary for anything added later: a floor or a contract placed under `canon/` would be exported
  with a catalogue and edited by its author to no effect — a lie told by the layout rather than by
  a comment.

  ## Why ONE root and not one variable per tree

  Nine trees, each with its own `LCARS_*` variable, would mean nine variables to set in order to
  bring ONE catalogue. That is `Fleet.Layout`'s warning turned inside out: over-exposing the
  structural forces the operator to re-declare a single intent nine times, and the ninth is the one
  they forget — which yields a fleet running THEIR cap-profiles over the BUNDLED SP fragments, a
  coherent-looking skew that no error message reports.

  A catalogue is ONE object. Pointing at it nine times denies it.

  The per-tree config keys stay as FINE OVERRIDES, and they keep precedence over this root: they
  predate it, tests drive them, and panachage (an operator's cap-profiles over the bundled modops)
  is a legitimate — if rarely wise — deployment. The coarse knob moves everything; a fine knob
  moves exactly its tree. Both narrownesses are now intentional instead of accidental.

  ## The default

  `root/0` defaults to the BUNDLED `priv/catalogue` — a directory that holds the nine trees and
  nothing else. The physical move that made it so (2026-08-01) changed exactly one line of this
  module: the `@rel_*` sub-paths were already root-relative, so they did not move. That was the
  point of expressing the layout once.

  What the directory buys beyond tidiness: **exporting a catalogue is copying one directory**. The
  runtime material — `priv/*/schema/`, `priv/cap_profile/baseline/`, `priv/sp_builder/sp_blocks/`
  (build-time only), `priv/canon/` (frozen legacy) — sits OUTSIDE it, so no export can carry a
  contract an author would edit to no effect.

  ## The manifest

  `<root>/catalogue.yaml` declares the contract version the catalogue targets. `verify!/0` reads it
  at boot, BEFORE the images freeze anything from the disk.

  This does NOT reopen per-file `apiVersion`: a cap-profile still carries none, and the schema that
  validates it is still chosen by the code. That rule answers "which schema validates THIS file"
  under a premise that holds today — the code and the YAML ship in one commit. The manifest answers
  a different question, which only exists once the premise breaks: "may this ARTIFACT, authored
  elsewhere and published on its own cadence, be consumed by this runtime at all". One file, at the
  root, about the whole; not a field on every file.

  Required, not optional, and introduced NOW for a reason that expires: a required manifest can be
  added while exactly one catalogue exists. Once a second one is in someone else's hands, making it
  required is a breaking change to a distributed artifact, and making it optional means a catalogue
  from a foreign generation fails at its first load without ever saying why.

  Foundation (`deps: []`, next to `Fleet.Layout` and `Fleet.Slug`): anything may depend down onto it.

  **Last revised**: 2026-08-02
  """

  require Logger

  @manifest_basename "catalogue.yaml"

  # Contract versions of the CATALOGUE this runtime can consume. A list, not a scalar: a runtime
  # able to read two generations is what makes an operator's upgrade ordered rather than atomic.
  @supported_api_versions [1]

  # ── the trees ─────────────────────────────────────────────────────────────
  # Root-relative, ONE literal each. These are the priv-relative paths in use today: the seam is
  # introduced without moving a single file, which is what keeps this lot revertible.
  @rel_cap_profiles "cap_profile/canon/cap-profiles"
  @rel_modops "cap_profile/canon/modop-bundles"
  @rel_subagent_templates "cap_profile/canon/subagent-templates"
  @rel_monk_registry "cap_profile/canon/cap-profiles/monks"
  @rel_sp_drafts "sp_builder/sp_drafts"
  @rel_sp_templates "sp_builder/templates"
  @rel_workflow_maps "workflow/canon/workflow_maps"
  @rel_brief_templates "workflow/brief_templates"
  @rel_coord_policies "coord/config/coord-policies.yaml"
  @rel_project_template "project_template"
  @rel_skills "skills/canon"

  @doc """
  Root of the catalogue. `LCARS_CATALOGUE_ROOT` (→ `:fleet_catalogue, :root`) or `priv/catalogue`.

  The default is `:code.priv_dir`-derived, NOT CWD-relative: it must resolve in a release
  (`lib/lcars_fleet-<vsn>/priv`) exactly as in dev, with no environment at all.
  """
  @spec root() :: Path.t()
  def root do
    # An explicit nil (a cross-test config leak) must never reach Path.join — coalesced here, at the
    # boundary, the same guard `CapProfile.Catalog.root_dir/0` carries for its own key.
    Application.get_env(:fleet_catalogue, :root) ||
      Application.app_dir(:lcars_fleet, "priv/catalogue")
  end

  @doc "Cap-profile YAMLs (`<root>/#{@rel_cap_profiles}`)."
  @spec cap_profiles_root() :: Path.t()
  def cap_profiles_root, do: Path.join(root(), @rel_cap_profiles)

  @doc "Modop SP fragments, `<root>/#{@rel_modops}/<name>/sp.md`."
  @spec modop_root() :: Path.t()
  def modop_root, do: Path.join(root(), @rel_modops)

  @doc "Subagent templates (`<root>/#{@rel_subagent_templates}/subagent-<name>.md`)."
  @spec subagent_templates_root() :: Path.t()
  def subagent_templates_root, do: Path.join(root(), @rel_subagent_templates)

  @doc """
  Monk memory registries. Derived from the ROOT and not from `cap_profiles_root/0`, although it sits
  under it: deriving it from the fine key would make `LCARS_CAPPROFILES_ROOT` silently move a second
  tree, which is the widening this module exists to make explicit.
  """
  @spec monk_registry_root() :: Path.t()
  def monk_registry_root, do: Path.join(root(), @rel_monk_registry)

  @doc "Generated role drafts (`<root>/#{@rel_sp_drafts}/agent-<role>-base.md`)."
  @spec sp_drafts_root() :: Path.t()
  def sp_drafts_root, do: Path.join(root(), @rel_sp_drafts)

  @doc "EEx templates giving every emitted prompt its shape (`<root>/#{@rel_sp_templates}`)."
  @spec sp_templates_root() :: Path.t()
  def sp_templates_root, do: Path.join(root(), @rel_sp_templates)

  @doc "Workflow-map YAMLs (`<root>/#{@rel_workflow_maps}`)."
  @spec workflow_maps_root() :: Path.t()
  def workflow_maps_root, do: Path.join(root(), @rel_workflow_maps)

  @doc "Brief templates rendered into forge tickets (`<root>/#{@rel_brief_templates}`)."
  @spec brief_templates_root() :: Path.t()
  def brief_templates_root, do: Path.join(root(), @rel_brief_templates)

  @doc "Escalation policy map — a FILE, not a directory (`<root>/#{@rel_coord_policies}`)."
  @spec coord_policies_path() :: Path.t()
  def coord_policies_path, do: Path.join(root(), @rel_coord_policies)

  @doc "Scaffolding copied into a freshly onboarded project (`<root>/#{@rel_project_template}/<face>`)."
  @spec project_template_root() :: Path.t()
  def project_template_root, do: Path.join(root(), @rel_project_template)

  @doc """
  Pod-mountable skills (`<root>/#{@rel_skills}/<name>/SKILL.md`) — filtered per cap-profile
  (`knowledge.skills` whitelist, `SPBuilder.filter_skills/2`) and bind-mounted RO into the pod's
  `~/.claude/skills/` (BL-6-22). The fine override is `:fleet_spawner, :skills_root`
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
  Boot check: the root is a readable directory, it carries a manifest, and that manifest targets a
  contract version this runtime supports. Returns the manifest map.

  Raises on every failure, each named separately — "no such root" and "root from a foreign
  generation" are different operator mistakes and a single message would send them to the wrong fix.
  Called by `Fleet.Application.start/2` BEFORE the images publish: freezing a snapshot of a
  catalogue that was never checked would carry the fault forward under a proven-good name.
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
        # Logged HERE and not by the caller, same rule as the images logging inside `publish!`: the
        # boot line names WHICH catalogue the fleet came up on, next to the versions frozen from it.
        Logger.info("Catalogue: verified (root=#{root}, api_version=#{version})")
        manifest

      other ->
        raise """
        LCARS catalogue: #{path} declares api_version #{inspect(other)}, this runtime consumes \
        #{inspect(@supported_api_versions)} — boot refused.
        The catalogue and the runtime are from incompatible generations; upgrade one of them.
        """
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
