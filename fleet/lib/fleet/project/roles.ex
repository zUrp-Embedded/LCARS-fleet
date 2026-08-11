defmodule Fleet.Project.Roles do
  @moduledoc """
  **Roles of the single-brick model** — accessors for the workshop's roles (producer, judges,
  gatekeeper). This module is the SINGLE accessor (without it the resolution would be rewritten in
  each caller). Override per project/test via the opts.

  The three roles live HERE: producer (`producer_role/1`), jury (`jury/2`) and gatekeeper
  (`gatekeeper_role/1`). `Fleet.Project.Onboard` and `Fleet.Pilot.GatekeeperSeal` delegate here
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
  `:fleet_pilot, :producer_role`; otherwise RESOLVED from the catalogue by the `producer` capability.

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
      Application.get_env(:fleet_pilot, :producer_role) ||
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
                "on; set `:fleet_pilot, :producer_role` if this deployment has one."

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
      Application.get_env(:fleet_pilot, :project_delegate_role) ||
      resolve_structural!(@delegate_capability, "project delegate", @delegate_uniqueness)
  end

  @doc """
  Boot check of the capabilities the fleet cannot work without. Called at rail boot
  (`Fleet.Pilot.Application`), and the demands DIFFER because the concepts do:

    * `producer` — **at least one**. Several is a legitimate catalogue (`eng_hw` + `eng_sw`): the
      card names which one it dispatches, per step. Refusing readiness for a specialised fleet would
      be the guard inventing a policy nobody asked for.
    * `exception_judge` — **exactly one**. `Fleet.Pilot.GatekeeperSeal` is the sole writer of the
      signed merge; two sealers is not a specialisation, it is an ambiguity about who signs.
    * `conflict_resolver` — **exactly one**. A tier-2 conflict is handed to a role, not broadcast.
    * `project_delegate` — **exactly one**, and it is the one this check was MISSING. Unlike the
      producer, nothing SELECTS a delegate: it is ensured per repo and no card names it. So a
      catalogue carrying two of them booted green and broke at the first `project_create`
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
  # could only be true of one. It said "single writer of the signed merge" for all three — accurate
  # for the gatekeeper, false for the two others, and it is the sentence an operator reads when the
  # boot refuses their catalogue.
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
  defp jury_of(nil, opts), do: Fleet.Workflow.Loader.load!(delegation_workflow_map(opts))["jury"]

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
  anything going red: swapping `"required"` for `"requis"` in the reader left the whole suite green
  (measured 2026-08-08). One site, one clause per enum member, and a mutation has nowhere to hide.

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
  Returns the CI policy of the project's declared card — the twin of `project_jury/2`, and it exists
  because the two were NOT twins.

  `ReviewLifecycle.issue_card_ci/2` claimed in comment to fall back "exactly like its jury"; its
  jury fallback read the PROJECT's declared card while its CI fallback answered a hardcoded
  `:ignore`. So a PR with no engraved route — a human PR, an adopted orphan — was judged under the
  project's jury and under NO CI policy, on a project whose card demands one. The comment described
  the code it should have had.
  """
  @spec project_ci(String.t(), keyword()) :: :required | :ignore
  def project_ci(repo, opts \\ []) when is_binary(repo), do: ci(load_project_card(repo, opts))

  defp load_project_card(repo, opts) do
    name = Fleet.Project.Intensity.pipeline_default(repo, opts)
    loader_opts = Keyword.take(opts, [:workflow_maps_root])

    try do
      Fleet.Workflow.Loader.load!(name, loader_opts)
    rescue
      e ->
        Logger.warning(
          "Roles: project card #{inspect(name)} for #{repo} does not load " <>
            "(#{Exception.message(e)}) — falling back to the delegation default card"
        )

        incident =
          Keyword.get(opts, :incident_fun, &Fleet.Project.Incidents.record_or_escalate/4)

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

        Fleet.Workflow.Loader.load!(delegation_workflow_map(opts), loader_opts)
    end
  end

  @doc """
  The card a project takes when it declares none — DECLARED by the catalogue, not defaulted here.

  It was the literal `"brief-gate"`, one catalogue's card: every catalogue shipping its own cards
  silently inherited a default naming a card it does not have. Unlike the doc rail, no property
  distinguishes this card from its siblings, so it is a choice and it is declared — the manifest
  says it, and `Fleet.Catalogue.verify!/0` refuses a catalogue that ships cards without naming one.
  """
  @spec delegation_workflow_map(keyword()) :: String.t() | nil
  def delegation_workflow_map(opts \\ []) do
    Keyword.get(opts, :delegation_workflow_map) || Fleet.Catalogue.default_card()
  end

  @doc """
  Returns the workflow map for routeless `genre/doc` issues, defaulting to `"workshop-direct"`.
  """
  @spec workshop_workflow_map(keyword()) :: String.t() | nil
  def workshop_workflow_map(opts \\ []) do
    Keyword.get(opts, :workshop_workflow_map) ||
      Fleet.Workflow.Loader.workshop_card_name(opts)
  end

  @doc """
  Returns the configured gatekeeper or the sole role with the `exception_judge` capability.
  """
  @spec gatekeeper_role(keyword()) :: String.t()
  def gatekeeper_role(opts \\ []) do
    Keyword.get(opts, :gatekeeper_role) ||
      Application.get_env(:fleet_pilot, :gatekeeper_role) ||
      resolve_structural!(@gatekeeper_capability, "gatekeeper", @gatekeeper_uniqueness)
  end

  @doc """
  TIER-2 CONFLICT RESOLVER — the role handed an unresolved merge conflict once the producer has
  spent its rework budget. Override by the opt `:conflict_resolver_role` (project/test), then config
  `:fleet_pilot, :conflict_resolver_role`; otherwise RESOLVED from the catalogue by the
  `conflict_resolver` capability. Raises on zero and on several, like every structural role.

  Its own capability, NOT `exception_judge`. The two responsibilities sit on the same role today,
  and that is a catalogue fact rather than a law: resolving a conflict means WRITING code on the
  PR, signing the merge means attesting it. Sharing one key would make moving the first move the
  second in silence — and the signatory of the seal is not something a remediation policy changes
  as a side effect. With two keys, substituting the resolver is a cap-profile edit that no file in
  `lib/` sees and that leaves the seal's signature exactly where it was.
  """
  @spec conflict_resolver_role(keyword()) :: String.t()
  def conflict_resolver_role(opts \\ []) do
    Keyword.get(opts, :conflict_resolver_role) ||
      Application.get_env(:fleet_pilot, :conflict_resolver_role) ||
      resolve_structural!(
        @conflict_resolver_capability,
        "conflict resolver",
        @conflict_resolver_uniqueness
      )
  end

  # (`architect_pod_id/1` — the singleton "permanent-architect" accessor + its config knob — was
  # REMOVED by the 2026-07-19 reorg: the architect is PER-PROJECT, its pod id derives from the repo
  # via the single authority `Fleet.Project.Architect.pod_id_for/1`.)
end
