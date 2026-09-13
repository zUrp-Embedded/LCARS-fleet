defmodule Fleet.Application.CatalogueVerify do
  @moduledoc """
  Runs catalogue checks using boot functions, without starting the supervision tree
  or validating deployment credentials. Use an ephemeral VM: verification publishes
  global images and only restores catalogue_root, not images or other configuration.
  boot.verifier_covers_rail checks stage coverage separately.
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
  Release eval entry: verifies root, prints assumptions/findings and exits 0 or 1.
  Uses the same verifier as the Mix task; ReleaseDoor reserves stdout for the report.
  """
  @spec eval_main(Path.t()) :: no_return()
  def eval_main(root) when is_binary(root) do
    Fleet.ReleaseDoor.claim_stdout!()

    case verify(root) do
      {:ok, %{assumptions: assumptions}} ->
        print(assumptions)
        # Report catalogue checks only; boot-stage coverage is a separate contract check.
        IO.puts(
          "catalogue OK — les controles catalogue du boot passent (cf. hypotheses ci-dessus)."
        )

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
  Temporarily sets catalogue_root and collects stage exceptions/throws/exits.
  Manifest failure skips everything downstream; either image failure skips spawn,
  card and business-advice stages. Otherwise those stages all run and accumulate
  findings. A stage's returned error tuple alone does not count as a finding.
  The report names the root and fine-override scope; it is not full deployment proof.
  """
  @spec verify(Path.t()) :: result()
  def verify(root) when is_binary(root) do
    prev = Application.fetch_env(:lcars_fleet, :catalogue_root)
    Application.put_env(:lcars_fleet, :catalogue_root, root)

    assumptions = [
      "root read: #{root}",
      "fine per-tree overrides (LCARS_CAPPROFILES_ROOT etc.) are IGNORED — this proves the root taken whole",
      cap_profiles_assumption(root)
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

  # A missing cap-profile directory can be intentional or misplaced. State it in
  # assumptions rather than refusing a valid catalogue that only uses system roles.
  defp cap_profiles_assumption(root) do
    dir = Path.join(root, Fleet.Catalogue.rel(:cap_profiles))

    if File.dir?(dir),
      do: "cap-profiles: read from #{dir}",
      else: "cap-profiles: NONE of its own (#{dir} absent) — its cards can only name system roles"
  end

  defp run(root, _assumptions) do
    case guard("catalogue manifest", fn -> Fleet.Catalogue.verify!() end) do
      [] -> after_manifest(root)
      findings -> {:error, findings}
    end
  end

  # Image failures suppress dependent stages to avoid cascading findings.
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
          # Match the boot card-to-role check before catalogue installation changes the forge.
          {"cards -> roles", fn -> Fleet.Workflow.CardRoles.verify!(root) end},
          {"business catalogue advice", fn -> advise_business!(root) end}
        ]
      else
        []
      end

    findings =
      image_findings ++ Enum.flat_map(downstream, fn {stage, fun} -> guard(stage, fun) end)

    case findings do
      [] -> :ok
      errs -> {:error, errs}
    end
  end

  # Same-name system-role overrides are supported. Conflicting slots/delegates are
  # checked in the merged index by image/structural-role validation, not forbidden
  # merely because a business file declares a system capability.
  # No judge in this root is advice, not refusal: zero-jury workflows are legitimate.
  # Other unreadable-index errors still raise; this is a root-local inspection.
  defp advise_business!(root) do
    cap_root = Path.join(root, "cap_profile/cap-profiles")

    case Fleet.CapProfile.index_of(cap_root) do
      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        raise "business catalogue advice: #{cap_root} unreadable (#{inspect(reason)})"

      {:ok, index} ->
        unless Enum.any?(index, &judge_role?/1) do
          Logger.warning(
            "business catalogue advice: this catalogue declares NO judge (`brief_kind: judge`). " <>
              "Legitimate — a card may carry `jury: []` and mean it — but nothing here can " <>
              "refuse a deliverable, so check it is a choice."
          )
        end

        :ok
    end
  end

  defp judge_role?({_name, raw}), do: get_in(raw, ["spec", "brief_kind"]) == "judge"

  # Only raised/thrown/exited failures produce findings; normal return values are ignored.
  defp guard(stage, fun) do
    fun.()
    []
  rescue
    e -> [%{stage: stage, error: Exception.message(e)}]
  catch
    kind, reason -> [%{stage: stage, error: "#{kind}: #{inspect(reason)}"}]
  end

  defp restore(:error), do: Application.delete_env(:lcars_fleet, :catalogue_root)
  defp restore({:ok, value}), do: Application.put_env(:lcars_fleet, :catalogue_root, value)
end
