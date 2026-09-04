defmodule Fleet.Project.Roles do
  @moduledoc """
  **Roles of the single-brick model** — accessors for the workshop's roles (producer, judges,
  gatekeeper). This module is the SINGLE accessor (without it the resolution would be rewritten in
  each caller). Override per project/test via the opts.

  The three roles live HERE: producer (`producer_role/1`), jury (`jury/2`) and gatekeeper
  (`gatekeeper_role/1`). `Fleet.Project.Onboard` and `Fleet.Pilot.MergeAndPromote` delegate here
  (never an `engineer`/`gatekeeper` literal rewritten at the caller).

  ## The structural roles are RESOLVED, not defaulted

  `producer_role/1` and `gatekeeper_role/1` carry **no literal default**. A default here would be
  a requirement that gave up on being verified: a catalogue naming no producer would boot green and
  fail at the first spawn, far from the deploy fault — what `Fleet.Spawner.CanonProof` prevents
  everywhere else.

  They resolve by CAPABILITY (`spec.capabilities`, the B-03 mechanism): `producer` for the one that
  codes the brick, `exception_judge` for the one that signs the merge. Substituting a role is a
  cap-profile edit, and there is no name the code falls back to when the catalogue is silent.

  Resolution is **fail-loud on zero AND on several**: for a structural role, an ambiguity is a broken
  catalogue, not a choice to arbitrate at random. `Fleet.Pilot.Application.validate_structural_roles!/0`
  runs it at boot, so a catalogue that cannot name its producer refuses readiness instead of dying at
  the first dispatch.
  """

  require Logger

  alias Fleet.Workflow.Loader

  # The capability each structural role is resolved BY. Not a role name: the point of B-03 is that a
  # gate resolves a responsibility, never a magic name.
  @producer_capability :producer
  @gatekeeper_capability :exception_judge
  # SEPARATE from `:exception_judge` on purpose, and the separation is the point. Whether one role
  # or two carry them is the CATALOGUE's call — a small shop puts both on its lead, a larger one
  # splits them. Resolving both through ONE key would take that call away and freeze it: "who
  # resolves an exhausted conflict" and "who signs the merge" would become the same decision
  # forever, so moving the first would silently move the second — and the seal's signatory is not
  # something a remediation policy gets to change as a side effect. Two keys cost nothing when a
  # catalogue puts them on the same role, and are the only way to ever put them on two.
  @conflict_resolver_capability :conflict_resolver
  @delegate_capability :project_delegate

  # Why each singleton is one, in the operator's terms. See `resolve_structural!/3`.
  @gatekeeper_uniqueness "single writer of the signed merge"
  @conflict_resolver_uniqueness "single addressee of a conflict the producer could not close"
  @delegate_uniqueness "single addressee of a project escalation, ensured per repo and named by no card"

  @doc """
  Producer role of LAST RESORT. Override by the opt `:producer_role` (project/test), then config
  `:lcars_fleet, :pilot_producer_role`; otherwise RESOLVED from the catalogue by the `producer` capability.

  ⚠ **This is NOT who produces.** The CARD names its producer per step (`steps.<name>.role`,
  schema-required), and the run carries it in the feature branch `lcars/issue-N-<producer>`. This
  accessor is the fallback of a single call site — `StepRunCompleter.producer_stop_role/2`, when the
  branch is absent or unparseable and a stopwatch stop still needs a real tokened identity.

  So SEVERAL producers is a legitimate catalogue: `eng_hw` and `eng_sw` both carry the capability,
  and every card says which one it dispatches. It raises only when this fallback is actually reached
  on such a catalogue — because there, genuinely, no answer exists, and signing as the wrong producer
  is worse than saying so.
  """
  @spec producer_role(keyword()) :: String.t()
  def producer_role(opts \\ []) do
    Keyword.get(opts, :producer_role) ||
      Application.get_env(:lcars_fleet, :pilot_producer_role) ||
      resolve_producer!()
  end

  defp resolve_producer! do
    case Fleet.CapProfile.roles_with_capability(@producer_capability) do
      {:ok, [role]} ->
        role

      {:ok, []} ->
        raise "Fleet.Project.Roles: no catalogue role declares the producer capability " <>
                "(#{inspect(@producer_capability)}) — no card can name a producer. Fix the catalogue."

      {:ok, roles} ->
        raise "Fleet.Project.Roles: #{length(roles)} roles declare the producer capability " <>
                "(#{inspect(roles)}), and this is the LAST-RESORT path — the card names the producer " <>
                "per step, the run carries it in the feature branch, and both were unavailable here. " <>
                "On a catalogue with several producers there is no fleet-wide default to fall back " <>
                "on; set `:lcars_fleet, :pilot_producer_role` if this deployment has one."

      {:error, reason} ->
        raise "Fleet.Project.Roles: cap-profile catalogue not enumerable (#{inspect(reason)}) while " <>
                "resolving the producer role — broken deploy, fail-loud."
    end
  end

  @doc """
  Returns the configured project delegate or the sole role with that capability.
  """
  @spec project_delegate_role(keyword()) :: String.t()
  def project_delegate_role(opts \\ []) do
    Keyword.get(opts, :project_delegate_role) ||
      Application.get_env(:lcars_fleet, :pilot_project_delegate_role) ||
      resolve_structural!(@delegate_capability, "project delegate", @delegate_uniqueness)
  end

  @doc """
  Boot check of the capabilities the fleet cannot work without. Called at rail boot
  (`Fleet.Pilot.Application`), and the demands DIFFER because the concepts do:

    * `producer` — **at least one**. Several is a legitimate catalogue (`eng_hw` + `eng_sw`): the
      card names which one it dispatches, per step. Refusing readiness for a specialised fleet would
      be the guard inventing a policy nobody asked for.
    * `exception_judge` — **exactly one**. `Fleet.Pilot.MergeAndPromote` is the sole writer of the
      signed merge; two sealers is not a specialisation, it is an ambiguity about who signs.
    * `conflict_resolver` — **exactly one**. A tier-2 conflict is handed to a role, not broadcast.
    * `project_delegate` — **exactly one**, and it is the easiest of the three to leave out. Unlike
      the
      producer, nothing SELECTS a delegate: it is ensured per repo and no card names it. Unchecked
      here, a catalogue carrying two of them boots green and breaks at the first `project_create`
      (`Fleet.Project.Architect`) or the first escalation (`Fleet.Pilot.ArchWake`) — hours after the
      deploy, on the operator's first real run, which is exactly the distance this module exists to
      remove.

  Returns the resolved singletons and the producer set for the caller.
  """
  @spec resolve_structural_roles!(keyword()) :: %{
          producers: [String.t()],
          gatekeeper: String.t(),
          conflict_resolver: String.t(),
          project_delegate: String.t()
        }
  def resolve_structural_roles!(opts \\ []) do
    %{
      producers: producers!(),
      gatekeeper: gatekeeper_role(opts),
      conflict_resolver: conflict_resolver_role(opts),
      project_delegate: project_delegate_role(opts)
    }
  end

  # AT LEAST one — the cards choose among them.
  defp producers! do
    case Fleet.CapProfile.roles_with_capability(@producer_capability) do
      {:ok, []} ->
        raise "Fleet.Project.Roles: no catalogue role declares the producer capability " <>
                "(#{inspect(@producer_capability)}) — no card could name a producer, the fleet " <>
                "produces nothing. Fix the catalogue."

      {:ok, roles} ->
        roles

      {:error, reason} ->
        raise "Fleet.Project.Roles: cap-profile catalogue not enumerable (#{inspect(reason)}) while " <>
                "resolving the producers — broken deploy, fail-loud."
    end
  end

  # The `why` is the SINGLETON's own reason, passed in by the caller rather than written once here:
  # the three roles are unique for three different reasons, and a single sentence covering them
  # could only be true of one ("single writer of the signed merge" fits the gatekeeper alone) — and
  # it is the sentence an operator reads when the boot refuses their catalogue.
  defp resolve_structural!(capability, label, why) do
    case Fleet.CapProfile.roles_with_capability(capability) do
      {:ok, [role]} ->
        role

      {:ok, []} ->
        raise "Fleet.Project.Roles: no catalogue role declares the #{label} capability " <>
                "(#{inspect(capability)}) — the single-brick model has no #{label}. A catalogue " <>
                "must NAME it; there is no default to fall back on. Fix the catalogue."

      {:ok, roles} ->
        raise "Fleet.Project.Roles: #{length(roles)} catalogue roles declare the #{label} capability " <>
                "(#{inspect(capability)}): #{inspect(roles)} — this one is unique BY DESIGN " <>
                "(#{why}), and picking one at random would be an arbitrary fleet-wide policy. " <>
                "Fix the catalogue."

      {:error, reason} ->
        raise "Fleet.Project.Roles: cap-profile catalogue not enumerable (#{inspect(reason)}) while " <>
                "resolving the #{label} role — broken deploy, fail-loud."
    end
  end

  @doc """
  Returns the card jury, or the injected `:reviewer_roles`. A `nil` card loads the delegation
  default.
  """
  @spec jury(map() | nil, keyword()) :: [String.t()]
  def jury(workflow_map, opts \\ []) do
    case Keyword.fetch(opts, :reviewer_roles) do
      {:ok, jury} when is_list(jury) -> jury
      :error -> jury_of(workflow_map, opts)
    end
  end

  defp jury_of(%{"jury" => jury}, _opts) when is_list(jury), do: jury
  defp jury_of(nil, opts), do: Loader.load!(delegation_workflow_map(opts))["jury"]

  @doc """
  Returns the jury of the project's declared card, checking `:reviewer_roles` first.

  An unloadable declaration logs, records an incident, and falls back to the delegation card. An
  empty card jury remains valid.
  """
  @spec project_jury(String.t(), keyword()) :: [String.t()]
  def project_jury(repo, opts \\ []) when is_binary(repo) do
    case Keyword.fetch(opts, :reviewer_roles) do
      {:ok, jury} when is_list(jury) -> jury
      :error -> jury_of(load_project_card(repo, opts), opts)
    end
  end

  @doc """
  Returns the card's CI policy as the atom `CiGate` decides on.

  THE ONLY SITE THAT KNOWS THE TOKENS. The schema enum and this function are the two ends of one
  contract, and while the comparison lived at the call site it could drift from the schema without
  anything going red: swapping `"required"` for `"requis"` in a reader placed at the call site
  leaves the whole suite GREEN. One site, one clause per enum member, and a mutation has nowhere
  to hide.

  THE LAST CLAUSE IS NOT A DEFAULT, IT IS AN ALARM. `spec.ci` is mandatory, so a card reaching here
  without a readable policy did not come through `Loader.load!`. Answering `:ignore` would rebuild
  the very hole the mandatory field closed — the un-declared card silently taking the permissive
  branch. It answers `:required` for the same reason `CiGate` treats an unreadable CI state as
  pending: unknown is not green, and the two costs are not symmetric. Being wrong here costs one
  status read; being wrong the other way costs a jury spent on code nobody built.
  """
  @spec ci(map() | nil) :: :required | :ignore
  def ci(%{"ci" => "required"}), do: :required
  def ci(%{"ci" => "ignore"}), do: :ignore

  def ci(card) do
    Logger.warning(
      "Roles: card #{inspect(get_card_name(card))} carries no readable `ci` policy " <>
        "(#{inspect(is_map(card) && Map.get(card, "ci"))}) — `spec.ci` is mandatory, so this card " <>
        "bypassed schema validation. Gating on CI rather than assuming green."
    )

    :required
  end

  defp get_card_name(card) when is_map(card), do: Map.get(card, "name")
  defp get_card_name(_), do: nil

  @doc """
  The card's VERDICT POLICY — its tolerance curve, or `nil` when it declares none.

  Single site that knows the field, exactly as `ci/1` is the single site that knows that enum: a
  rename must have one place to fail. `nil` is a VALUE here ("this card declares no curve"), never
  a default invented on absence — `Jury.review_outcome/4` given `nil` is indistinguishable from the
  boolean aggregation, which is what lets the canon migrate one card at a time.

  NO WARNING ON ABSENCE, and that is the difference with `ci/1`: `spec.ci` is mandatory to the
  schema, so a card without it bypassed validation and deserves to be shouted at. `verdict_policy`
  is optional by design — most cards will never carry one, and a line of log per verdict for a
  field nobody promised would train a reader to skip the logs that matter.
  """
  @spec verdict_policy(map() | any()) :: map() | nil
  def verdict_policy(%{"verdict_policy" => %{} = policy}), do: policy
  def verdict_policy(_card), do: nil

  @doc "Verdict policy of the PROJECT's declared card — twin of `project_ci/2`, same fallback family."
  @spec project_verdict_policy(String.t(), keyword()) :: map() | nil
  def project_verdict_policy(repo, opts \\ []) when is_binary(repo),
    do: verdict_policy(load_project_card(repo, opts))

  @doc """
  The verdict policy that applies to a PR, resolved from the ISSUE's engraved card when a route
  exists and from the PROJECT's declared card otherwise.

  ⚠ UNE SEULE FONCTION, PARCE QUE DEUX LECTEURS EN DÉPENDENT ET QU'ILS DOIVENT DIRE LA MÊME CHOSE.
  `Jury.review_outcome` est décrit dans son propre @doc comme « the SINGLE truth of where a jury
  stands », partagé par le gate de merge et la lecture de statut de l'arch, « factored so the status
  surface can NEVER drift from what the gate actually does ». Une politique résolue deux fois —
  une par appelant — rendrait cette phrase fausse le jour où les deux copies divergent, et la
  divergence serait invisible : le gate refuserait, l'arch lirait « approuvé ».

  Elle prend le client forge en ARGUMENT plutôt que de le nommer : ses deux appelants vivent dans
  des domaines qui ne se voient pas (le pilote et la surface pod), et c'est le seul détail qui les
  sépare. Le reste — route, chargement, repli — est ici, une fois.

  Fail-safe : toute panne de lecture rend `nil`, c'est-à-dire l'agrégation booléenne. Une carte
  illisible ne doit pas pouvoir DURCIR un rail par accident ; elle le laisse où il était.
  """
  @spec verdict_policy_for(module(), String.t(), integer(), keyword()) :: map() | nil
  def verdict_policy_for(forge, repo, issue_number, opts \\ [])
      when is_binary(repo) and is_integer(issue_number) do
    forge_opts = Keyword.get(opts, :forge_opts, [])

    with {:ok, {map_name, _step}} <- forge.get_route(repo, issue_number, forge_opts),
         {:ok, card} when is_map(card) <- safe_load_card(map_name, repo) do
      verdict_policy(card)
    else
      _ -> verdict_policy(load_project_card(repo, opts))
    end
  end

  # `load!` raises on an unloadable card; here a raise would take down a gate tick over a curve that
  # is optional in the first place. Rescued into the same `nil` every other failure yields — the
  # project card fallback right above stays the interesting path, and an unreadable engraved card
  # is reported by the routing that OWNS that failure, not invented a second time here.
  defp safe_load_card(map_name, repo) do
    {:ok, Loader.load!(map_name, Loader.card_opts_for_repo(repo))}
  rescue
    _ -> :error
  end

  @doc """
  Returns the CI policy of the project's declared card — the twin of `project_jury/2`, and it has to
  exist for the two to BE twins.

  A CI fallback answering a hardcoded `:ignore`, beside a jury fallback that reads the PROJECT's
  declared card, makes a PR with no engraved route — a human PR, an adopted orphan — judged under
  the project's jury and under NO CI policy, on a project whose card demands one. That is the shape
  `ReviewLifecycle.issue_card_ci/2` would take under a comment claiming to fall back "exactly like
  its jury".
  """
  @spec project_ci(String.t(), keyword()) :: :required | :ignore
  def project_ci(repo, opts \\ []) when is_binary(repo), do: ci(load_project_card(repo, opts))

  defp load_project_card(repo, opts) do
    name = Fleet.Project.Declaration.pipeline_default(repo, opts)
    loader_opts = Keyword.take(opts, [:workflow_maps_root])

    # THE PROJECT'S OWN CATALOGUE, and it must be consulted. Naming the card and letting the loader
    # answer from the default root — the BUNDLED catalogue — makes a project belonging to any other
    # one ask for a card the loader published under another key, and be told it does not exist.
    # Measured: `web/test2` declares `standard`, the `web` catalogue carries it, and the
    # fleet raised `declared_card_unloadable` on every tick while falling back to a card the human
    # never chose. Falling back to another catalogue's default is worse than failing: the project
    # runs, quietly, under a criticality nobody declared for it.
    #
    # The org names the catalogue (that is the point of naming it so), and an unclaimed org keeps
    # the default — an explicit `:workflow_maps_root` still wins, it is the fixture's own door.
    loader_opts =
      case {loader_opts, Loader.card_root_for_repo(repo)} do
        {[], dir} when is_binary(dir) -> [catalogue_root: dir]
        {given, _} -> given
      end

    try do
      Loader.load!(name, loader_opts)
    rescue
      e ->
        Logger.warning(
          "Roles: project card #{inspect(name)} for #{repo} does not load " <>
            "(#{Exception.message(e)}) — falling back to the delegation default card"
        )

        incident =
          Keyword.get(opts, :incident_fun, &Fleet.Project.Incidents.emit/4)

        _ =
          try do
            incident.("card", repo, :declared_card_unloadable,
              reason_detail: "#{inspect(name)}: #{Exception.message(e)}"
            )
          catch
            kind, why ->
              Logger.warning(
                "Roles: fallback incident NOT recorded (#{inspect(kind)}: #{inspect(why)})"
              )
          end

        Loader.load!(delegation_workflow_map(opts), loader_opts)
    end
  end

  @doc """
  The card a project takes when it declares none — DECLARED by the catalogue, not defaulted here.

  A literal here — `"brief-gate"`, one catalogue's card — makes every catalogue shipping its own
  cards silently inherit a default naming a card it does not have. Unlike the doc rail, no property
  distinguishes this card from its siblings, so it is a choice and it is declared — the manifest
  says it, and `Fleet.Catalogue.verify!/0` refuses a catalogue that ships cards without naming one.
  """
  @spec delegation_workflow_map(keyword()) :: String.t() | nil
  def delegation_workflow_map(opts \\ []) do
    Keyword.get(opts, :delegation_workflow_map) || Fleet.Catalogue.default_card()
  end

  @doc """
  The workflow map serving routeless `destination/workshop` issues — the catalogue's doc rail.

  ⚠ NO DEFAULT NAME, whatever a `@doc` may be tempted to claim (`"workshop-direct"` is one
  catalogue's card). The rail resolves by a PROPERTY (a card carrying a `face: workshop` producer),
  so
  each catalogue answers with ITS own card and a catalogue shipping none answers `nil` — which the
  boot warns about by name. A default here would hand one catalogue's card to every other.
  """
  @spec workshop_workflow_map(keyword()) :: String.t() | nil
  def workshop_workflow_map(opts \\ []) do
    Keyword.get(opts, :workshop_workflow_map) ||
      Loader.workshop_card_name(workshop_scope(opts))
  end

  # `catalogue_root: <repo>` is accepted as a REPO here and resolved to that project's cards. The
  # doc rail is resolved by a PROPERTY (a card carrying a `face: workshop` producer), and the
  # property searched in the default catalogue whatever the project makes a `web` ticket burn the
  # `fleet` catalogue's rail, whose producer is `scribe` — an account that is a member of no `web`
  # team. The push and the PR both answer `403 user must be a collaborator`, which reads as a
  # permissions defect and is a card coming from the wrong catalogue.
  defp workshop_scope(opts) do
    case Keyword.get(opts, :catalogue_root) do
      repo when is_binary(repo) -> Loader.card_opts_for_repo(repo)
      _ -> opts
    end
  end

  @doc """
  Returns the configured gatekeeper or the sole role with the `exception_judge` capability.
  """
  @spec gatekeeper_role(keyword()) :: String.t()
  def gatekeeper_role(opts \\ []) do
    Keyword.get(opts, :gatekeeper_role) ||
      Application.get_env(:lcars_fleet, :pilot_gatekeeper_role) ||
      resolve_structural!(@gatekeeper_capability, "gatekeeper", @gatekeeper_uniqueness)
  end

  @doc """
  THE MERGE RAIL — the role that writes on git for the pipeline: it resolves a tier-2 conflict the
  producer could not close, AND it signs every merge, its push, and the head-branch delete.

  Override by the opt `:conflict_resolver_role` (project/test), then config
  `:lcars_fleet, :pilot_conflict_resolver_role`; otherwise RESOLVED from the catalogue by the
  `conflict_resolver` capability. Raises on zero and on several, like every structural role.

  ## ⚠ The capability key says `conflict_resolver`, and it now names a SUBSET of the job

  ⚖ user: the rails are separated by DOMAIN — this one merges, the gatekeeper decides — so this
  role signs EVERY merge, not only the conflicted ones. Its key and its cap-profile header describe
  a narrower job, the one it was created for.

  The key is DELIBERATELY not renamed here, and the reason is the one this codebase keeps paying
  for: a capability key is a catalogue contract. Renaming it in `lib/` alone would leave every
  cap-profile declaring a capability nothing resolves, and the boot validator would refuse to start —
  loudly, but for a reason nobody would connect to a doc edit. The rename belongs to a catalogue
  pass (key + profiles + structural-role validator + the chief's SP), taken whole or not at all.

  Until then this docstring IS the correction: the key is historical, the job is the merge rail.

  ## Why it is its own capability, NOT `exception_judge`

  The two responsibilities live on separate roles, and the reason is a SECURITY property the schema
  requires declared: their briefs carry opposite `brief_kind` values — `judge` ("never execute what
  you judge") and `worker` ("execute it") — and one role cannot declare both. Merging is an
  execution. Sharing one key would let a catalogue edit move the write capability onto the JUDGING
  role, in silence.
  """
  @spec conflict_resolver_role(keyword()) :: String.t()
  def conflict_resolver_role(opts \\ []) do
    Keyword.get(opts, :conflict_resolver_role) ||
      Application.get_env(:lcars_fleet, :pilot_conflict_resolver_role) ||
      resolve_structural!(
        @conflict_resolver_capability,
        "conflict resolver",
        @conflict_resolver_uniqueness
      )
  end

  # No singleton "permanent-architect" accessor here: the architect is PER-PROJECT, and its pod id
  # derives from the repo through the single authority `Fleet.Project.Architect.pod_id_for/1`.
end
