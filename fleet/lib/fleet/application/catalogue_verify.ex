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

      bin/fleet_umbrella eval 'Fleet.Application.CatalogueVerify.eval_main("/cat")'

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
  defp run(_root, _assumptions) do
    case guard("catalogue manifest", fn -> Fleet.Catalogue.verify!() end) do
      [] -> after_manifest()
      findings -> {:error, findings}
    end
  end

  # Tier 2 — the two proven-good images. The spawn proof and the card guards read the FROZEN image,
  # so a failed publish would make them fail too, as cascade noise. If either image fails, we skip
  # those two and still prove the policies (which read their own file), then report.
  defp after_manifest do
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
