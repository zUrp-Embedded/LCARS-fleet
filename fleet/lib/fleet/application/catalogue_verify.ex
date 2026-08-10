defmodule Fleet.Application.CatalogueVerify do
  @moduledoc """
  Standalone catalogue-root proof using the daemon's own verification functions in
  boot order. It proves one directory, not deployment credentials or fine-grained
  overrides, and must run in an ephemeral VM because image publication is global.
  """

  require Logger

  @typedoc "One failed check: which stage, and the raised message verbatim."
  @type finding :: %{stage: String.t(), error: String.t()}

  @typedoc """
  The verdict. `:ok` when every stage passed; `{:error, findings}` otherwise. `assumptions` is
  always returned — the root read and the fine-override blindness the header must show.
  """
  @type result ::
          {:ok, %{root: Path.t(), assumptions: [String.t()]}}
          | {:error, %{root: Path.t(), findings: [finding()], assumptions: [String.t()]}}

  @doc """
  The RELEASE door: run `verify/1`, print the same report the `mix` task prints, and halt with the
  boot's verdict (0 pass, 1 refused). Called from the image's entrypoint via a release eval —

      bin/lcars_fleet eval 'Fleet.Application.CatalogueVerify.eval_main("/cat")'

  so the entrypoint's `verify <root>` is a one-liner and the exit code is the whole contract on the
  shell side. Uses `IO.puts` + `System.halt/1` because a release has no `Mix.shell` — the ONLY
  difference from the dev door, the checks themselves being identical (they are `verify/1`).
  """
  @spec eval_main(Path.t()) :: no_return()
  def eval_main(root) when is_binary(root) do
    case verify(root) do
      {:ok, %{assumptions: assumptions}} ->
        print(assumptions)
        IO.puts("catalogue OK — every check the boot runs passed.")
        System.halt(0)

      {:error, %{findings: findings, assumptions: assumptions}} ->
        print(assumptions)
        IO.puts("catalogue REFUSED — #{length(findings)} check(s) failed:")
        for %{stage: stage, error: error} <- findings, do: IO.puts("  x #{stage}: #{error}")
        System.halt(1)
    end
  end

  defp print(assumptions) do
    IO.puts("- verifier assumptions -")
    for a <- assumptions, do: IO.puts("  . #{a}")
    IO.puts("")
  end

  @doc """
  Verifies the catalogue at `root`. Sets `:fleet_catalogue, :root` to it for the duration, restores
  the previous value on the way out. Collects findings instead of raising on the first — an operator
  fixes a catalogue in one pass, not one boot-crash at a time — but keeps the boot's tiers: the
  manifest is a precondition (nothing downstream is meaningful without it), and the images are a
  precondition for the spawn proof and the card guards (both read the frozen image, so a failed
  image would cascade into noise). The escalation policies read their own file and are proved
  regardless.
  """
  @spec verify(Path.t()) :: result()
  def verify(root) when is_binary(root) do
    prev = Application.fetch_env(:fleet_catalogue, :root)
    Application.put_env(:fleet_catalogue, :root, root)

    assumptions = [
      "root read: #{root}",
      "fine per-tree overrides (LCARS_CAPPROFILES_ROOT etc.) are IGNORED — this proves the root taken whole"
    ]

    try do
      case run(root, assumptions) do
        :ok ->
          {:ok, %{root: root, assumptions: assumptions}}

        {:error, findings} ->
          {:error, %{root: root, findings: findings, assumptions: assumptions}}
      end
    after
      restore(prev)
    end
  end

  # Tier 1 — the manifest. Without a readable root and a supported api_version, nothing below can be
  # published or proved; a precondition, so it short-circuits.
  defp run(root, _assumptions) do
    case guard("catalogue manifest", fn -> Fleet.Catalogue.verify!() end) do
      [] -> after_manifest(root)
      findings -> {:error, findings}
    end
  end

  # Tier 2 — the two proven-good images. The spawn proof and the card guards read the FROZEN image,
  # so a failed publish would make them fail too, as cascade noise. If either image fails, we skip
  # those two and still prove the policies (which read their own file), then report.
  defp after_manifest(root) do
    image_findings =
      Enum.flat_map(
        [
          {"cap-profile image", fn -> Fleet.CapProfile.publish_image!() end},
          {"sp-builder image", fn -> Fleet.SPBuilder.publish_image!() end}
        ],
        fn {stage, fun} -> guard(stage, fun) end
      )

    downstream =
      if image_findings == [] do
        [
          {"canon spawn-proof", fn -> Fleet.Spawner.prove_canon!() end},
          {"cards + structural roles",
           fn -> Fleet.Pilot.Application.verify_cards_and_roles!() end},
          {"business conformance", fn -> conform_business!(root) end},
          {"escalation policies", fn -> Fleet.Coord.init_policies!() end}
        ]
      else
        # Images broke → the spawn proof and card guards would only echo it. Policies are
        # independent (own file), so they are still worth a real verdict.
        [{"escalation policies", fn -> Fleet.Coord.init_policies!() end}]
      end

    findings =
      image_findings ++ Enum.flat_map(downstream, fn {stage, fun} -> guard(stage, fun) end)

    case findings do
      [] -> :ok
      errs -> {:error, errs}
    end
  end

  # The capabilities that belong to the MECHANISM. Each is resolved by the runtime alone, and each
  # is unique fleet-wide — nothing selects them, so a business catalogue declaring one takes over a
  # decision that is not its to make. `producer` is deliberately absent: it is the ONE capability a
  # card selects, which is exactly what makes it business.
  @system_capabilities ~w(onboarder project_delegate exception_judge conflict_resolver)

  # Conformance of the BUSINESS half, judged alone — what this catalogue DECLARES, not what it
  # inherits. Two refusals and one warning.
  #
  # The two refusals draw the frontier: a business role carrying a system capability would take the
  # seal's signatory (or the delegate, or the arbiter) away from the mechanism, and `role_index: 0`
  # is the fleet-scope slot — the one that exists before any repository and that the reaper spares.
  # Both are properties of the machinery, and neither is a choice a catalogue gets to make.
  #
  # The warning is a warning on purpose: a catalogue with no judge is LEGITIMATE (a card may
  # declare `jury: []` and mean it), it is just almost always an oversight. Refusing it would set a
  # policy this check has no mandate for — the same restraint `validate_workshop_card!/1` applies.
  #
  # A producer is NOT re-checked here: `resolve_structural_roles!/0` already refuses a deployment
  # that names none, and it does it on the UNION, which is the right perimeter for that question.
  defp conform_business!(root) do
    cap_root = Path.join(root, "cap_profile/canon/cap-profiles")

    case Fleet.CapProfile.index_of(cap_root) do
      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        raise "business conformance: #{cap_root} unreadable (#{inspect(reason)})"

      {:ok, index} ->
        roles = Map.to_list(index)

        usurped =
          for {name, raw} <- roles,
              cap <- get_in(raw, ["spec", "capabilities"]) || [],
              cap in @system_capabilities,
              do: "#{name} declares #{cap}"

        if usurped != [] do
          raise "business conformance: #{Enum.join(Enum.sort(usurped), ", ")} — these " <>
                  "capabilities belong to the system catalogue: the runtime resolves each of them " <>
                  "alone and fleet-wide. A business catalogue names its producers and its judges; " <>
                  "it does not name who signs a merge."
        end

        fleet_scoped =
          for {name, raw} <- roles, get_in(raw, ["metadata", "role_index"]) == 0, do: name

        if fleet_scoped != [] do
          raise "business conformance: #{Enum.join(Enum.sort(fleet_scoped), ", ")} declare " <>
                  "role_index 0 — that slot is the FLEET-scope one (it exists before any " <>
                  "repository and the reaper never kills it), and it belongs to the system " <>
                  "catalogue. Use 1..15."
        end

        unless Enum.any?(roles, fn {_n, raw} -> get_in(raw, ["spec", "brief_kind"]) == "judge" end) do
          Logger.warning(
            "business conformance: this catalogue declares NO judge (`brief_kind: judge`). " <>
              "Legitimate — a card may carry `jury: []` and mean it — but nothing here can " <>
              "refuse a deliverable, so check it is a choice."
          )
        end

        :ok
    end
  end

  # Runs one stage. `[]` on success, a one-element finding list on any raise/throw — the boot raises,
  # the verifier collects, so the caller sees every failure the deployment would have hit.
  defp guard(stage, fun) do
    fun.()
    []
  rescue
    e -> [%{stage: stage, error: Exception.message(e)}]
  catch
    kind, reason -> [%{stage: stage, error: "#{kind}: #{inspect(reason)}"}]
  end

  defp restore(:error), do: Application.delete_env(:fleet_catalogue, :root)
  defp restore({:ok, value}), do: Application.put_env(:fleet_catalogue, :root, value)
end
