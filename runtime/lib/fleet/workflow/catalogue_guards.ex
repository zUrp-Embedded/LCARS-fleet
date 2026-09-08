defmodule Fleet.Workflow.CatalogueGuards do
  @moduledoc """
  What a catalogue's CARDS must satisfy before anything is served from them — the `validate_*!`
  family the step rail plays at boot and the standalone verifier replays: every jury role is a
  judge, every step role resolves in the card's own catalogue and never sits on its own jury, the
  default card loads, and a catalogue without a doc rail is told so. Each guard raises on the
  first broken card, at the deploy fault and not at the first dispatch.

  Beside `CardRoles`, the card→role edge the OTP root verifies: same question, same owner — the
  catalogue. One caller outside the domain, `Fleet.Pilot.Application`, at rail boot and again
  through its `verify_cards_and_roles!/1` that `Fleet.Application.CatalogueVerify` replays before
  touching the forge.
  """

  require Logger

  alias Fleet.Workflow.Loader

  # EVERY installed catalogue is proved, not just the bundled one. `canon_names!/1` with no opts
  # reads the image of the BUNDLED root: called that way, another catalogue's cards are validated by
  # nobody and meet their first reader at dispatch — far from the boot that could refuse them.
  # Explicit opts mean "this root and no other": that is the per-catalogue verifier naming its
  # target.
  #
  # Each scope carries its catalogue ROOT beside the card directory. The root is not decoration: a
  # card names roles, and a role only exists in the catalogue that declares it. Validating `web`'s
  # `standard` — jury `[code-reviewer]` — against the FIRST catalogue's image raises `:not_found` on
  # a card that is perfectly coherent with itself, and kills the boot. The pair travels together or
  # the reader resolves in the wrong world.
  defp card_scopes([]) do
    Enum.map(Loader.card_scopes(), &{[workflow_maps_root: &1.dir], &1.root})
  end

  # Explicit opts name ONE directory and no catalogue: roles resolve in the default image, which is
  # what a fixture-driven test and the per-catalogue verifier both want.
  defp card_scopes(opts), do: [{opts, nil}]

  @doc "Every jury role of every card resolves in the card's catalogue AND is a judge; raises otherwise."
  @spec validate_card_juries!(keyword()) :: :ok
  def validate_card_juries!(opts \\ []) do
    for {scope, root} <- card_scopes(opts),
        map_name <- Loader.canon_names!(scope),
        role <- Loader.load!(map_name, scope)["jury"] do
      validate_jury_role!(Fleet.CapProfile.load(role, root), map_name, role)
    end

    :ok
  end

  defp validate_jury_role!({:ok, cp}, map_name, role) do
    kind = Fleet.CapProfile.brief_kind(cp)

    unless kind == "judge" do
      raise "catalogue: workflow map #{map_name} jury contains #{inspect(role)} whose cap-profile " <>
              "is NOT a judge (brief_kind=#{inspect(kind)}) — the jury must be judge roles. Fix the card."
    end
  end

  defp validate_jury_role!({:error, reason}, map_name, role) do
    raise "catalogue: workflow map #{map_name} jury contains #{inspect(role)} that does NOT resolve " <>
            "to a cap-profile (#{inspect(reason)}) — a non-role login in a jury WEDGES at dispatch " <>
            "(no cap-profile → :no_role). Fix the card."
  end

  @doc "Warns when a catalogue ships no card with a `face: workshop` producer — a legitimate deployment, said."
  # The doc rail is resolved by PROPERTY — the card carrying a `face: workshop` producer — so there
  # is no name to check for coherence any more. `Fleet.Workflow.Loader.publish_image!/0` refuses two
  # claimants, which is what makes the resolution total; what is left here is telling the operator
  # when a catalogue simply has no rail. That is a legitimate deployment, not a defect: refusing the
  # boot there would be a policy this check has no mandate to set.
  #
  # Guarding a NAME instead — a knob holding one catalogue's card name — would need three regimes,
  # two of which exist only because a name can be wrong. A property cannot.
  @spec validate_workshop_card!(keyword()) :: :ok
  def validate_workshop_card!(opts \\ []) do
    for {scope, _root} <- card_scopes(opts) do
      if Loader.workshop_card_name(scope) == nil do
        Logger.warning(
          "catalogue: no doc card in #{inspect(Keyword.get(scope, :workflow_maps_root))} — no " <>
            "card there carries a `face: workshop` producer, so this catalogue serves NO " <>
            "`destination/workshop` ticket. Ship one, or route those tickets elsewhere."
        )
      end
    end

    :ok
  end

  # This guard needs the catalogue's MANIFEST as well as its cards, and `card_scopes/1` drops the
  # root for the explicit-opts form — a fixture could name a directory of cards but never the
  # catalogue that declares a default among them. `:catalogue_root` closes that: one key, and the
  # guard is drivable from a test instead of only from a boot.
  defp default_card_scopes([]),
    do: Enum.map(Loader.card_scopes(), &{[workflow_maps_root: &1.dir], &1.root})

  defp default_card_scopes(opts), do: [{opts, Keyword.get(opts, :catalogue_root)}]

  @doc "The manifest\'s default card LOADS (YAML, schema, graph) — `Catalogue.verify!/0` only checks its name."
  # THE DEFAULT CARD MUST LOAD AT BOOT, and this is the ONLY place that proves it.
  # `Fleet.Catalogue.verify!/0` checks the default card's NAME is among the cards (`card in cards`);
  # it does not LOAD it. A default whose YAML is unreadable, schema-invalid, or graph-invalid would
  # reach readiness GREEN and die at the first undeclared project's dispatch, far from the deploy
  # fault. We load it HERE, fail-loud, same dead-man's-switch as the card guards above.
  #
  # No intensity level to cover: the card alone carries the gate, a project declares its criticality
  # BY naming a card, and a card that loads is a card that can serve. What is proved is the load
  # itself — the guarantee `Catalogue.verify!` does not give.
  @spec validate_default_card_loads!(keyword()) :: :ok
  def validate_default_card_loads!(opts \\ []) do
    for {scope, root} <- default_card_scopes(opts),
        is_binary(root),
        card_name = Fleet.Catalogue.default_card(root),
        is_binary(card_name) do
      _ = Loader.load!(card_name, scope)
    end

    :ok
  end

  @doc "Every step role of every card resolves in the card\'s catalogue and never sits on that card\'s jury."
  # Symmetric to validate_card_juries!, for the STEP roles. The schema guards the SHAPE of
  # spec.steps.*.role (any string) but not the CONTENT: a typo or a retired role passes the boot
  # and only WEDGES at the first dispatch (`StepDispatcher` → `CapProfile.resolve` → :not_found, a
  # stuck ticket that never spawns). We resolve every canon step role at boot — a role that cannot
  # load = a broken canon, fail-loud HERE. A step without a role (nil) is skipped: it is not a
  # dispatch role. (`opts` carries `:workflow_maps_root` for tests; prod calls it argument-less.)
  @spec validate_card_steps!(keyword()) :: :ok
  def validate_card_steps!(opts \\ []) do
    for {scope, root} <- card_scopes(opts),
        map_name <- Loader.canon_names!(scope),
        card = Loader.load!(map_name, scope),
        {step_name, spec} <- card["steps"] || %{},
        role = Map.get(spec, "role"),
        is_binary(role) do
      case Fleet.CapProfile.load(role, root) do
        {:ok, cp} ->
          refute_self_judgement!(map_name, step_name, role, cp, card["jury"])

        {:error, reason} ->
          raise "catalogue: workflow map #{map_name} step #{inspect(step_name)} has role " <>
                  "#{inspect(role)} that does NOT resolve to a cap-profile (#{inspect(reason)}) — a bad " <>
                  "canon role WEDGES at dispatch (CapProfile.resolve → :not_found, stuck ticket). Fix the card."
      end
    end

    :ok
  end

  # A PRODUCER MAY NOT SIT ON THE JURY THAT JUDGES ITS OWN DELIVERY. The card names both halves and
  # nothing compared them: `jury` is the set of roles whose approvals gate the seal, `steps[].role`
  # is who produces — and a role in both reviews the PR it opened. The pipeline would report a
  # normal approval, because every mechanism involved worked exactly as written.
  #
  # `brief_kind` IS THE DISCRIMINANT, not the step's position. A judge role appearing as a step is
  # legitimate and shipped: `gk-smoke` runs a `reviewer` step with a soft gate, and `reviewer` is
  # also in its jury — two different acts on two different objects. Only a `worker` opens the
  # deliverable PR the jury then judges, so only a worker can collide with itself here.
  #
  # AT BOOT, over the whole canon, because a card is DATA an operator can bring: catching this at
  # dispatch would mean catching it per ticket, on the ticket, after the spawn.
  defp refute_self_judgement!(map_name, step_name, role, cp, jury) do
    if Fleet.CapProfile.brief_kind(cp) == "worker" and is_list(jury) and role in jury do
      raise "catalogue: workflow map #{map_name} step #{inspect(step_name)} PRODUCES as " <>
              "#{inspect(role)}, and #{inspect(role)} is also in that card's jury " <>
              "#{inspect(jury)} — the producer would review its own PR and its approval would " <>
              "count toward the seal. Nothing downstream can tell that apart from a real review. " <>
              "Remove the role from the jury, or give the step a different producer."
    end

    :ok
  end
end
