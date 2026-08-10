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
  @rel_sp_blocks "sp_builder/sp_blocks"
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

  @doc """
  Root of the SYSTEM catalogue — the mechanism, never the business.

  Four roles live there and no card names any of them: the fleet-level front desk (`role_index: 0`,
  which has to exist before any repository does), the project delegate, the seal's signatory and
  the tier-2 conflict resolver. The runtime resolves each of them BY CAPABILITY, alone, to hold its
  own machinery — which is exactly the test: a role a card names is business, a role only the
  runtime looks for is mechanism.

  ## Why this is not a second knob

  The argument above against nine variables holds, and this does not contradict it: the system root
  is NOT an operator variable. It is embedded and resolved by `:code.priv_dir`, like `schema/` and
  `baseline/`, for the same reason — **what an operator must not be able to replace is a contract**.
  An operator brings their business; they do not choose their mechanism.

  That is also what finally makes "this catalogue is complete" checkable. With everything in one
  tree the sentence has no meaning: a business catalogue would have to carry the machinery, so
  missing it and choosing differently look identical. Split, the two halves answer separately — the
  system is present and intact, the business is conforming.

  Both catalogues are read through ONE search path (`search/2`), business first: a business
  catalogue that ships a file where the system also ships one REPLACES it, the child-theme rule.
  """
  @spec system_root() :: Path.t()
  def system_root do
    # `:system_root` is a TEST SEAM, and the distinction from a knob is the whole point: it has no
    # env var, no line in the env template and no `config/runtime.exs` reader, so no deployment can
    # set it. Without it no test could build an ISOLATED catalogue — every fixture root would
    # silently inherit the four mechanism roles and measure a deployment nobody assembled. A seam
    # a test can reach and an operator cannot is not the knob this module argues against.
    Application.get_env(:fleet_catalogue, :system_root) ||
      Application.app_dir(:lcars_fleet, "priv/catalogue-system")
  end

  @doc "Path of the system manifest."
  @spec system_manifest_path() :: Path.t()
  def system_manifest_path, do: Path.join(system_root(), @manifest_basename)

  @doc """
  The SEARCH PATH of a tree: the business directory, then the system one — existing only.

  **The order IS the precedence, and it is written here once.** Every reader goes through the four
  functions below; none of them knows there are two roots, and adding a third one day is one line
  here and zero elsewhere. That property is the whole point, and its absence was the defect: the
  same resolution had been hand-rolled at fourteen call sites behind three copies of the same
  helper, and the three readers that never learned it were three bugs — a permanent pod
  respawn-looping on a skill (W-11), a conversation contract demanded from a catalogue that has no
  human-facing role (W-13), a dormant extension point aimed at the wrong root (W-14).

  `business` is resolved BY ITS DOMAIN (that is where the fine per-tree overrides live) and passed
  in; `rel` is the tree's path inside the system catalogue. Absent directories are dropped, which
  is what lets the system catalogue ship only what its four roles need instead of empty trees.

  **Business first.** A catalogue that ships a file at a path the system also ships REPLACES it —
  the child-theme rule. An operator who drops their own `rubber-duck` means it; the attacker is
  never the operator.
  """
  @spec search(Path.t(), String.t()) :: [Path.t()]
  def search(business, rel) when is_binary(business) and is_binary(rel) do
    Enum.filter([business, Path.join(system_root(), rel)], &File.dir?/1)
  end

  @doc """
  First existing `name` on the search path — the BUSINESS path when it exists nowhere.

  Returning the business path rather than `nil` is deliberate: the caller's own `:enoent` then names
  the file its author would have to create, instead of a path in a tree they do not own.
  """
  @spec find(Path.t(), String.t(), String.t()) :: Path.t()
  def find(business, rel, name) when is_binary(name) do
    paths = Enum.map(search(business, rel), &Path.join(&1, name))
    Enum.find(paths, Path.join(business, name), &File.regular?/1)
  end

  @doc "Every path matching `glob` on the search path, in precedence order."
  @spec glob(Path.t(), String.t(), String.t()) :: [Path.t()]
  def glob(business, rel, pattern) when is_binary(pattern) do
    Enum.flat_map(search(business, rel), &Path.wildcard(Path.join(&1, pattern)))
  end

  @doc """
  `pattern` merged across the search path into `%{key => path}` — the FIRST root wins.

  `Map.put_new` and not `Map.merge`: precedence must survive the fold, and a later root silently
  overwriting an earlier one is the inversion this module exists to prevent.
  """
  @spec merge(Path.t(), String.t(), String.t(), (Path.t() -> term())) :: %{term() => Path.t()}
  def merge(business, rel, pattern, key_fun) when is_function(key_fun, 1) do
    business
    |> glob(rel, pattern)
    |> Enum.reduce(%{}, fn path, acc -> Map.put_new(acc, key_fun.(path), path) end)
  end

  @doc "Relative path of a shared tree inside a catalogue — the ONE literal each, for `search/2`."
  @spec rel(atom()) :: String.t()
  def rel(:cap_profiles), do: @rel_cap_profiles
  def rel(:modops), do: @rel_modops
  def rel(:subagent_templates), do: @rel_subagent_templates
  def rel(:sp_drafts), do: @rel_sp_drafts
  def rel(:sp_blocks), do: @rel_sp_blocks
  def rel(:sp_templates), do: @rel_sp_templates
  def rel(:skills), do: @rel_skills

  @doc """
  SP blocks, BUSINESS root (`<root>/#{@rel_sp_blocks}`) — the search path is `search/2`.

  BUILD-TIME material, and the only tree here that a running fleet never reads: the composer turns
  it into `sp_drafts/`, and the pods read those. It is a catalogue tree all the same, because the
  system half of it (`core/`) is a shipped DEFAULT an operator supersedes by name, exactly like the
  two `protocole-user-*`.
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
  Verifies that the root is readable and its manifest targets a supported
  generation, then returns the manifest. Failures raise with operator-facing
  diagnostics.
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
