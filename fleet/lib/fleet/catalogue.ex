defmodule Fleet.Catalogue do
  use Boundary, deps: [], exports: []

  @moduledoc """
  The single authority for WHERE the catalogue lives — an ORDERED SEARCH PATH, one sub-path per
  tree.

  There are several roots: the INSTALLED catalogues, then the system default last, and a reader
  asks for a TREE (`search(:modops)`) rather than naming a root. `search/2` and its siblings remain
  for the two callers that legitimately name their own — the composer under `--catalogue`, and the
  spawn path whose skills root is its own three-state knob.

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

  One `LCARS_*` variable per tree would mean as many variables to set in order to bring ONE
  catalogue. That is `Fleet.Layout`'s warning turned inside out: over-exposing the structural forces
  the operator to re-declare a single intent N times, and the last one is the one they forget —
  which yields a fleet running THEIR cap-profiles over the BUNDLED SP fragments, a coherent-looking
  skew that no error message reports.

  A catalogue is ONE object. Pointing at it once per tree denies it.

  The per-tree config keys stay as FINE OVERRIDES, and they keep precedence over this root: they
  predate it, tests drive them, and panachage (an operator's cap-profiles over the bundled modops)
  is a legitimate — if rarely wise — deployment. The coarse knob moves everything; a fine knob
  moves exactly its tree. Both narrownesses are intentional, not accidental.

  ## The default

  `root/0` defaults to the BUNDLED `priv/catalogue` — a directory that holds the catalogue trees
  and nothing else. (How MANY is deliberately not written here: an inventory in prose is false the
  day a tree is added, and `rel/1` is the place that has to be right.)

  What the directory buys beyond tidiness: **exporting a catalogue is copying one directory**. The
  runtime material — `priv/*/schema/`, `priv/cap_profile/baseline/`, `priv/canon/` (frozen legacy) —
  sits OUTSIDE it, so no export can carry a contract an author would edit to no effect.

  ⚠ `sp_builder/sp_blocks/` lives INSIDE both catalogues (`core/` is a shipped default an author
  supersedes by name, the rest is their own material) and is build-time all the same — a running
  fleet never reads it. Build-time is a property of WHEN a tree is read, not of where it lives, so
  it does not decide which side of this line a tree sits on.

  ## The manifest

  `<root>/catalogue.yaml` declares the contract version the catalogue targets, and its NAME.
  `verify!/0` reads it at boot, BEFORE the images freeze anything from the disk.

  The name is a property OF THE CATALOGUE, not of its installation. Assigned at install time — by a
  CLI argument, or defaulting to the source basename — the same catalogue on two boxes carries two
  names. That is harmless only while the name is a local handle for the declaration file and the
  verbs; it stops being harmless because the name addresses something OUTSIDE the box, the forge org
  that carries a catalogue's projects. A project created in org `web` is unopenable where the same
  catalogue answers to `frontend`.

  Kebab-case, and `_` is refused where `Fleet.Slug` allows it: the underscore is the separator of the
  `<catalogue>_<role>` account login, so admitting it in either half would make the split ambiguous.

  This does NOT reopen per-file `apiVersion`: a cap-profile still carries none, and the schema that
  validates it is still chosen by the code. That rule answers "which schema validates THIS file"
  under a premise that holds today — the code and the YAML ship in one commit. The manifest answers
  a different question, which only exists once the premise breaks: "may this ARTIFACT, authored
  elsewhere and published on its own cadence, be consumed by this runtime at all". One file, at the
  root, about the whole; not a field on every file.

  Required, not optional, for a reason with a shelf life: a manifest can be made required only while
  every catalogue in existence is in this repository. Once a second one is in someone else's hands,
  requiring it is a breaking change to a distributed artifact — and leaving it optional means a
  catalogue from a foreign generation fails at its first load without ever saying why.

  Foundation (`deps: []`, next to `Fleet.Layout` and `Fleet.Slug`): anything may depend down onto it.
  """

  require Logger

  @manifest_basename "catalogue.yaml"

  # Contract versions of the CATALOGUE this runtime can consume. A list, not a scalar: a runtime
  # able to read two generations is what makes an operator's upgrade ordered rather than atomic.
  @supported_api_versions [1]

  # STRICTER than `Fleet.Slug` on purpose: no `_`. The underscore separates the two halves of a role
  # account login (`<catalogue>_<role>`), so admitting it in a catalogue name would make `a_b_c`
  # readable as two different splits. Slug stays as it is — it guards paths, a different job.
  @name_rx ~r/\A[a-z0-9][a-z0-9-]*\z/

  # ── the trees ─────────────────────────────────────────────────────────────
  # Root-relative, ONE literal each.
  @rel_cap_profiles "cap_profile/canon/cap-profiles"
  @rel_modops "cap_profile/canon/modop-bundles"
  @rel_subagent_templates "cap_profile/canon/subagent-templates"
  @rel_monk_registry "cap_profile/canon/cap-profiles/monks"
  @rel_sp_drafts "sp_builder/sp_drafts"
  @rel_sp_blocks "sp_builder/sp_blocks"
  @rel_sp_templates "sp_builder/templates"
  @rel_workflow_maps "workflow/canon/workflow_maps"
  @rel_brief_templates "workflow/brief_templates"
  @rel_project_template "project_template"
  @rel_skills "skills/canon"

  # LES AVATARS, nommes par le ROLE et non par le compte. La recette porte une table
  # `<compte>:<image>` tenue a la main, donc elle doit connaitre les roles d'un catalogue tiers —
  # un fichier nomme par le role, dans le catalogue qui le declare, n'a besoin d'aucun index.
  # FACULTATIF par nature (⚖ user) : un catalogue sans avatar s'installe, ses comptes
  # portent l'identicon de Gitea. Un role que personne n'a dessine n'a pas d'avatar, et c'est normal.
  @rel_avatars "avatars"

  @doc """
  Root of the BUNDLED catalogue — and the root a caller holding no catalogue resolves to.

  `LCARS_CATALOGUE_ROOT` (→ `:lcars_fleet, :catalogue_root`) or `priv/catalogue`. The default is
  `:code.priv_dir`-derived, NOT CWD-relative: it must resolve in a release
  (`lib/lcars_fleet-<vsn>/priv`) exactly as in dev, with no environment at all.

  ## It is THE default, and that is why it has a name

  It is also the head of `installed_roots/0`, by construction rather than by coincidence — the list
  is built from this function. Spelling that default `hd(installed_roots())` READS as "whichever
  catalogue happens to be first" while the mechanism guarantees a constant, so it invites a
  reordering of `installed_roots/0` to silently change every such resolution — and it names a
  POSITION where the thing has a NAME.
  """
  @spec root() :: Path.t()
  def root, do: to_string(bundled_root())

  # THE BUNDLED ROOT IS THE BUSINESS ROOT OF A CALLER WITHOUT A CATALOGUE.
  #
  # `search/1` covers the trees BOTH halves of a deployment share — cap-profiles, modops, drafts,
  # blocks… The purely business trees (workflow maps, brief templates, project_template) have no
  # system default, so they read this root DIRECTLY. A caller that resolves its ROLES in one
  # catalogue and its CARDS here gets a coherent-looking half-wiring: a card whose jury names a role
  # the other catalogue does not carry. The boot refuses that one LOUDLY — it is the same
  # "coherent-looking skew" this module's header warns about, one level up.
  defp bundled_root do
    # An explicit nil (a cross-test config leak) must never reach Path.join — coalesced here, at the
    # boundary, the same guard `CapProfile.Catalog.root_dir/0` carries for its own key.
    Application.get_env(:lcars_fleet, :catalogue_root) ||
      Application.app_dir(:lcars_fleet, "priv/catalogue")
  end

  @doc """
  Root of the SYSTEM catalogue — the mechanism, never the business.

  The roles living there are the ones no card names — the runtime resolves each BY CAPABILITY,
  alone, to hold its own machinery. That IS the test: a role a card names is business, a role only
  the runtime looks for is mechanism.

  ## Why this is not a second knob

  The argument above against one variable per tree holds, and this does not contradict it: the system
  root
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
    # silently inherit the mechanism roles and measure a deployment nobody assembled. A seam
    # a test can reach and an operator cannot is not the knob this module argues against.
    Application.get_env(:lcars_fleet, :catalogue_system_root) ||
      Application.app_dir(:lcars_fleet, "priv/catalogue-system")
  end

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

  # The FINE overrides, gathered from the four domains that held them. Each moves EXACTLY its tree
  # and nothing else, which is what "fine" means next to the big wheel (`LCARS_CATALOGUE_ROOT`,
  # which moves a whole catalogue).
  #
  # ⚠ A fine override REPLACES the active list for its tree, it does not sit in front of it — and
  # that is load-bearing rather than a detail of taste. `Fleet.Test.CatalogueIsolation` builds an
  # isolated catalogue by pointing these keys at a fixture; if the shipped business root stayed
  # behind, every such fixture would silently inherit roles nobody wrote and the suite would measure
  # a deployment nobody assembled. The system root is never dropped either way: it is the contract,
  # not a participant in precedence.
  #
  # Trees with no entry have no fine override, deliberately: `sp_templates` and `sp_blocks` are the
  # shape and the substrate of the prompts, and nothing has ever needed to move one alone.
  @fine_overrides %{
    cap_profiles: {:lcars_fleet, :cap_profile_root_dir},
    modops: {:lcars_fleet, :sp_builder_modop_root},
    subagent_templates: {:lcars_fleet, :sp_builder_subagent_template_root},
    sp_drafts: {:lcars_fleet, :sp_builder_sp_drafts_root}
  }

  @doc """
  The ordered search path for one TREE, named by its atom — the N-root door.

  Where `search/2` asks the caller for a business root, this resolves the whole precedence itself:
  the fine override for that tree if one is set, otherwise every INSTALLED catalogue in order, and the
  system default last. Absent directories drop out, so a catalogue that ships only what its roles
  need costs nothing.

  This is the form a domain should use. `search/2` remains for the callers that legitimately NAME
  their root — the composer under `--catalogue`, and the spawn path whose skills root is its own
  three-state knob — and there are exactly two of them.
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

  # ⚠ `find/2` ET `glob/2` (les portes par ARBRE, aplaties sur tous les installes) ONT ETE TUEES
  # ICI, et l'absence est le point : elles resolvaient un nom au premier catalogue qui l'avait,
  # TOUS catalogues confondus — la dette `search/1` des trois audits. Leur dernier appelant (les
  # protocoles de pod) resout desormais par `tree_scope/2` + `find_in/2`, le scope d'UN catalogue
  # plus le systeme. Un nouveau lecteur qui croit avoir besoin d'une recherche tous-catalogues a en
  # main un appelant qui ne sait pas a quel catalogue il appartient — c'est CE probleme-la qu'il
  # faut resoudre, pas celui du chemin. `merge/3` (meme famille, zero appelant) est parti avec.

  # The name of the business catalogue shipped inside the release. `fleet` and not `lcars`: the
  # name is destined to become an identifier OUTSIDE this code (the forge org that carries a
  # catalogue's projects), and `lcars` is already taken there by LCARS's own repository — an org
  # `lcars` holding a repo `lcars` reads as a mistake. `fleet/lcars` is what the forge already
  # shows, and it stays true when the org becomes the catalogue.
  @bundled_name "fleet"

  @doc """
  The name the catalogue shipped inside the release declares.

  PUBLIC because a second site needs it — `Fleet.Application.CatalogueLifecycle` had its own
  `@bundled "fleet"`, and two literals for one fact drift the day one of them is changed. The name
  is load-bearing beyond this module: it is the forge ORG that carries the reference catalogue's
  projects, so it cannot be installed FROM the forge and no deposit can ever claim it.
  """
  @spec bundled_name() :: String.t()
  def bundled_name, do: @bundled_name

  @doc """
  The INSTALLED catalogues, as roots — `#{@bundled_name}` first, then the material present on this
  box, by name.

  ## Installed is a PRESENCE, not a declaration

  NO SECOND FACT beside this one — in particular no ACTIVITY declaration, one name per line in a
  file the operator edits, deciding WHICH of the installed catalogues actually runs. Its absence is
  the point of this function's shape.

  Two facts that can disagree about the same question will disagree, and both skews are expensive:
  a catalogue declared active while the forge carries neither its org nor its role accounts boots
  the fleet on a roster nobody assembled, which then loops at the first dispatch on tokens that were
  never minted — far from the line that asked for it. The reverse is quieter still: a catalogue
  installed on the forge and absent from the declaration is polled by nobody, so its projects simply
  never move, and no message says why.

  One fact answers it. The material is HERE, or it is not.

  ## What makes the material appear

  `lcars catalogue install <name>`, played by an admin — the single verb. It lays the org and the
  role accounts on the forge, pushes the catalogue's source into `<name>/_catalogue`, and drops the
  material here. Convergent provisioning replays the second half at every container boot, so this
  directory is a CACHE of what the forge carries rather than a state anyone maintains by hand.
  Deleting a directory here does not uninstall anything; the next boot puts it back.

  ## Why the bundled one is first and unconditional

  `#{@bundled_name}` ships inside the release, so it is installed by construction and cannot be
  removed — deliberately, so that ONE valid catalogue is always present. That is an AVAILABILITY
  guarantee and not an authority: it is a peer, and a role or a card of another catalogue never
  resolves in it.

  It comes first because a caller with no project in hand has to resolve SOMEWHERE, and the
  complete catalogue that always works is the honest default. The order below it is the name order
  — deterministic, and belonging to nobody.

  The system catalogue is not in this list and cannot be: it is always last, implicitly, and it is
  a contract rather than a participant.
  """
  @spec installed_roots() :: [Path.t()]
  def installed_roots do
    [root() | installed_dirs()]
  end

  # WHERE the material sits arrives by CONFIG, and this module stays `deps: []`.
  #
  # It is a platform fact, so its authority is `Fleet.Layout` — but calling it from here would add a
  # dep to the module whose layer name is the one mechanically checkable thing in the topology
  # (`foundation ≡ deps: []`, CLAUDE.md). The edge creates no cycle and would still turn a derived
  # fact into one the map asserts by hand. `config/runtime.exs` passes the paths instead, which is
  # where every other deployment fact already enters.
  #
  # Unset — the whole of `:test`, and any deployment that never wired it — means the shipped
  # catalogue alone.
  #
  # ⚠ Do NOT "simplify" this into `System.user_home!/0` here. It is CACHED by the VM: probed,
  # `put_env("HOME", …)` then `user_home!()` still answers the boot-time value, so a
  # test moving HOME would silently measure the real `~/.lcars` of whoever ran the suite.
  defp install_dirs, do: Application.get_env(:lcars_fleet, :catalogue_install_dirs, [])

  # A directory counts as a catalogue when it carries a MANIFEST, not merely because it exists.
  # Half a `git clone`, an editor's backup directory or a stray `lost+found` would otherwise enter
  # the roster and take down the boot on a verify nobody asked for.
  #
  # `@bundled_name` is excluded rather than shadowed: it is already first, and a second entry under
  # the same name would publish two images for one catalogue.
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
  The CATALOGUE roots, in precedence order — business first, then the system default.

  `search/2` answers "where do I look for this TREE"; this answers "which catalogues am I made of".
  The difference matters to a check that must attribute a fault to a catalogue rather than to a
  directory: a role and its SP live in two different trees of the SAME catalogue, and pairing them
  through `search/2` alone would compare tree i of one with tree i of another.

  ⚠ A FINE override (`:lcars_fleet, :cap_profile_root_dir` and its siblings) moves one tree OUT of its
  catalogue, and no pairing survives that by construction — the tree is then, deliberately, not part
  of any catalogue. Callers that attribute per catalogue must say so.
  """
  @spec roots() :: [Path.t()]
  def roots, do: Enum.filter(installed_roots() ++ [system_root()], &File.dir?/1)

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
  def rel(:avatars), do: @rel_avatars
  def rel(:cap_profiles), do: @rel_cap_profiles
  def rel(:modops), do: @rel_modops
  def rel(:subagent_templates), do: @rel_subagent_templates
  def rel(:sp_drafts), do: @rel_sp_drafts
  def rel(:sp_blocks), do: @rel_sp_blocks
  def rel(:sp_templates), do: @rel_sp_templates
  def rel(:skills), do: @rel_skills

  # ⚠ UNE ABSENCE ICI EST UN MECANISME, PAS UN OUBLI : `rel/1` est ce qu'un appelant utilise pour
  # adresser un arbre sous une racine ARBITRAIRE, donc un arbre qui manque a cette table ne peut
  # etre adresse que sous `root/0` — le catalogue livre. Les cartes ne sont PAS un chemin de
  # recherche (elles ne se superposent pas), mais elles sont adressables par racine, ce qu'exige la
  # publication d'une image par catalogue.
  def rel(:workflow_maps), do: @rel_workflow_maps
  # Meme mecanisme, meme consequence : sans clause ici, le template de projet ne s'adresserait que
  # sous `root/0`, donc TOUT projet de la boite serait echafaude depuis le catalogue de reference
  # pendant que le sien livre les fichiers que rien ne lit. Pas un chemin de recherche non plus — un
  # template ne se superpose pas, c'est l'arbre dont un nouveau projet part.
  #
  # ⚠ ONE TREE IS STILL `root/0`-ONLY, and it is measured rather than assumed: `brief_templates`
  # (read by `Workflow.BriefTemplate`). Same latent skew — a catalogue's own would never be read —
  # not closed here because no caller holds the catalogue in hand today. (Its former twin,)
  def rel(:project_template), do: @rel_project_template

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

  @doc """
  One search path per installed catalogue for a TREE — the per-catalogue door, next to `search/1` which
  merges them all.

  `search/1` answers "everything this deployment can see for this tree", which is what a global view
  wants (a dashboard, a contracts check). This answers "what does catalogue N see", which is what a
  PROJECT wants: its own catalogue over the system, and nothing from its neighbours.

  The FINE override still REPLACES the list — one scope, that directory over the system — for the
  same reason it does in `search/1`: a fixture pointing a tree at its own root is building an
  isolated catalogue, and leaving the shipped ones behind would make it read material nobody wrote.
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
  The search path of ONE catalogue for ONE tree: its own directory, then the system's.

  The per-tree door under `scopes/1`, for a consumer whose object spans SEVERAL trees — the SP image
  covers four, and asking `scopes/1` four times would give four lists to zip, with no defined answer
  when a tree carries a fine override (one entry) and another does not (N).

  **A fine override replaces its tree for EVERY catalogue.** Measured before choosing: those keys are
  set only by tests (`:subagent_template_root` by nobody at all), never by `lib/` or `config/`, and a
  fixture that sets one runs a single catalogue. The regime where "one override, N catalogues" would
  read as N copies of the same directory is therefore a state nothing reaches.
  """
  @spec tree_scope(Path.t(), atom()) :: [Path.t()]
  def tree_scope(root, tree) when is_binary(root) and is_atom(tree) do
    rel = rel(tree)
    own = fine_override(tree) || Path.join(root, rel)
    Enum.filter([own, Path.join(system_root(), rel)], &File.dir?/1)
  end

  @doc "First existing `name` on an EXPLICIT scope (`tree_scope/2`), or nil — no config consulted."
  @spec find_in([Path.t()], String.t()) :: Path.t() | nil
  def find_in(scope, name) when is_list(scope) and is_binary(name) do
    Enum.find_value(scope, fn dir ->
      path = Path.join(dir, name)
      if File.regular?(path), do: path
    end)
  end

  @doc """
  The workflow-map directory of EVERY installed catalogue, in `installed_roots/0` order.

  Cards do not supersede across catalogues and never will: a card names roles, and a role belongs to
  the catalogue that declares it — a card from one catalogue over the roles of another describes a
  fleet nobody assembled. So this is a LIST of roots to publish one image each from, not a search
  path to merge. The system root is absent on purpose: it carries the mechanism, no business card.
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

  @doc """
  The repo name the fleet WRITES a catalogue's store under, inside that catalogue's own org.

  ## This is an ADDRESS. It must never become a predicate again.

  Answering "is this repo a store?" by comparing this name reserves the most natural repo name in
  every user's namespace, and reserves it in SILENCE — a deposit called `catalogue` gets dropped
  with no log, no line, no refusal. The question is answered by IDENTITY instead
  (`owner == manifest.name`, `CatalogueDeposits.split/2`), which holds whatever the repo is called.

  The one legitimate read is a WRITE COLLISION: *"am I about to create a repo where `push_store`
  force-pushes?"* — `Onboard.adopt_project/2`. That does not decide what an existing repo IS; it
  decides where a new one may be put. Any other reader is the old defect coming back.

  The `_` prefix is UX (⚖ user): in a list of repos it separates at a glance what the
  fleet put there from what a human deposited. It protects nothing.

  The shell writers hold their own copy (`STORE_REPO` in `forge-gestures.sh`, which pushes it, and
  in `45-catalogues.sh`, which clones from it) — three defaults in three runtimes, not three
  authorities, the same posture as `SYSTEM_ACCOUNT`.
  """
  @spec store_repo() :: String.t()
  def store_repo, do: "_catalogue"

  @doc """
  The file a catalogue declares itself in, by BASENAME — what a forge reader asks for at a repo's
  root, where `manifest_path/0` is what a disk reader opens under `root/0`. One literal for both.
  """
  @spec manifest_file() :: String.t()
  def manifest_file, do: @manifest_basename

  @doc """
  The `name:` a manifest declares — `{:ok, name}` or `{:error, :no_name_in_manifest}`.

  ## One rule, and it lives HERE because two boundaries ask it

  Three sites ask a repo what catalogue it claims to be: the deposit listing
  (`Fleet.Application.CatalogueDeposits`), the explicit-door guard (`Fleet.Project.Onboard`), and
  `45-catalogues.sh` in shell. The first two are in boundaries that may not reference each other,
  and widening one to reach the other to be right is never the move — so the rule sits in the
  foundation both may descend onto. The shell copy is unavoidable (a different runtime) and says so.

  The manifest is read for ONE field. A full YAML parse would make a listing fail on a catalogue
  whose unrelated section is malformed — the identity is what is needed here, and `catalogue verify`
  is what judges the rest.

  ⚠ COLUMN ZERO, and it is the whole correctness of this read. In YAML an INDENTED `name:` belongs
  to the key above it: `roles:\n  name: dev` declares a role, not the catalogue. Accepting leading
  whitespace would let the first nested `name:` in the file steal the catalogue's identity — and it
  would work by accident on OUR manifests, where the root key happens to come first, then be wrong
  on somebody else's.

  ⚠ `[_, name | _]` and not `[_, name]`: the trailing comment group makes `Regex.run/2` return
  THREE elements when a comment is present, so a two-element pattern falls through to "no name" —
  silently, on a line as ordinary as `name: web   # le metier`.
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

  # The name is REQUIRED for the same reason the manifest itself is: it can only be made required
  # while every catalogue in existence is in this repository. Optional would mean falling back to
  # the directory name, which is precisely the defect — a name assigned by whoever installed,
  # differing between two boxes holding the same catalogue.
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
        catalogue outside this box (the forge org carrying its projects), so it cannot be the \
        directory someone happened to unpack it into.
        """

      other ->
        raise "LCARS catalogue: #{path} declares a non-string name (#{inspect(other)}) — boot refused."
    end
  end

  # WHICH card a project gets when it declares none. Not a resolution — no property distinguishes the
  # default from its siblings, unlike the doc rail (`face: workshop`) — so it is a CHOICE, and a
  # choice is declared. It lived as a literal in `Fleet.Project.Roles` (`"brief-gate"`, one
  # catalogue's card): every catalogue that shipped its own cards silently inherited a default that
  # named a card it does not have.
  #
  # Required exactly when it means something: a catalogue that ships NO card has no default to name
  # (the system catalogue), and one that ships cards must say which — and must name one of its own,
  # checked by FILENAME here rather than by loading, because this module is foundation and the loader
  # is not below it.
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
  The catalogue's declared NAME. `verify!/0` validates it at boot; this is the reader.

  It addresses the catalogue outside this box — the prefix of its role accounts
  (`<catalogue>_<role>`), and the forge org that will carry its projects.
  """
  @spec name() :: String.t() | nil
  def name do
    case YamlElixir.read_from_file(manifest_path()) do
      {:ok, %{"name" => n}} when is_binary(n) -> n
      _ -> nil
    end
  end

  @doc """
  The declared name of EVERY installed catalogue, in `installed_roots/0` order — the forge orgs
  this deployment discovers on.

  A catalogue that declares no name is skipped rather than defaulted: the name is required and
  `verify!/0` refuses its absence, so a root without one is a root the boot has not blessed.
  """
  @spec installed_names() :: [String.t()]
  def installed_names, do: installed_catalogues() |> Enum.map(& &1.name) |> Enum.uniq()

  @doc """
  Every installed catalogue as `%{name, root}`, in `installed_roots/0` order — THE pairing.

  Three readers want it in three shapes (the poller wants the orgs, the card listing wants
  name-plus-cards-dir, the enroller wants the root), and re-reading the manifest in each is how the
  same fact acquires three answers. One authority, one read.

  A root whose manifest declares no name is skipped rather than defaulted: the name is required and
  `verify!/0` refuses its absence, so a root without one is a root the boot has not blessed.
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
  Root of the installed catalogue NAMED `name`, or `nil` — the pairing read by its other end.

  It exists because the dispatch rail knows a project by its forge repo, and a project lives in the
  org of its catalogue: the `owner` of `owner/name` IS the catalogue name (lot 4 of the org-par-
  catalogue chantier). So a step run carries, for free, the catalogue that must resolve its roles —
  and this is the function that spends it.

  `nil` for a name no installed catalogue answers to. That is not a defect to guard against: the
  poller only discovers on the orgs of INSTALLED catalogues, so a work item for a catalogue absent
  from this box does not exist. Callers treat `nil` as "no catalogue named, resolve in the default
  image", which is what every pre-catalogue caller already did.
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
  The same root, from a repo's `owner/name` — the form the dispatch rail actually holds.

  It exists so the split is written ONCE. Three call sites derived it separately within an hour of
  each other, which is how one fact acquires three answers and how they start to disagree.
  """
  @spec root_for_repo(String.t() | nil) :: Path.t() | nil
  def root_for_repo(full_name) when is_binary(full_name) do
    full_name |> String.split("/") |> List.first() |> root_for()
  end

  def root_for_repo(_), do: nil

  @doc """
  The card a project of THIS catalogue gets when it declares none, or `nil` for a catalogue with no
  cards. Read from the manifest, so it is the catalogue's answer and not the runtime's.
  """
  @spec default_card() :: String.t() | nil
  def default_card, do: default_card(root())

  @doc """
  The same card, for ONE catalogue root — every INSTALLED catalogue has its own, and a guard that
  checks them has to ask each in turn rather than the default one N times.
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
