defmodule Fleet.Workflow.CatalogueGuards do
  @moduledoc """
  Card checks used by Pilot.Application at boot and by CatalogueVerify before provisioning.
  Checks loaded card juries, worker self-judgement and default-card loading; absence of a
  workshop card is only a warning. CardRoles separately inventories role references.
  """

  require Logger

  alias Fleet.Workflow.Loader

  # Keep each default card scope paired with its root for role resolution, avoiding a peer's image.
  defp card_scopes([]) do
    Enum.map(Loader.card_scopes(), &{[workflow_maps_root: &1.dir], &1.root})
  end

  # Explicit opts use one card scope but nil role root, even if opts includes catalogue_root.
  defp card_scopes(opts), do: [{opts, nil}]

  @doc "Checks loaded cards' top-level jury roles resolve as judges; explicit opts use the default role root."
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
  # Workshop selection comes from the producer's face; duplicate-claimant rejection belongs to Loader.
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

  # Unlike role guards, the default-card guard honors explicit catalogue_root to read its manifest.
  defp default_card_scopes([]),
    do: Enum.map(Loader.card_scopes(), &{[workflow_maps_root: &1.dir], &1.root})

  defp default_card_scopes(opts), do: [{opts, Keyword.get(opts, :catalogue_root)}]

  @doc "Loads the manifest's default card; skips non-binary roots or default names (including absent explicit root)."
  # Checking name membership alone does not exercise Loader's YAML/schema/graph checks.
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

  @doc "Resolves binary step roles and rejects worker roles on the card's top-level jury; non-binary roles are skipped."
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

  # A worker must not approve its own delivery. Judge steps can also sit on the card jury
  # (e.g. gk-smoke/reviewer): role kind, not step position, decides this restriction.
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
