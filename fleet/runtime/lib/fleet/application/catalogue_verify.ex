defmodule Fleet.Application.CatalogueVerify do
  @moduledoc """
  Standalone verification of a catalogue root — the boot proof, run off the supervision path.

  ## One truth, two doors

  The daemon proves its catalogue as it boots: `Fleet.Catalogue.verify!` (root + manifest +
  `api_version`), the two proven-good images, `CanonProof.prove_all!`, the card jury/step guards,
  the structural-role resolution and the escalation-policy load — each raised by a different
  domain's `Application`. This module runs the SAME functions, in the same order, against an
  arbitrary root, so an operator editing a catalogue can prove it before a fleet ever tries to boot
  on it. It calls those functions; it never re-lists their checks — a divergent copy would be one
  more dialect of "valid", the exact thing `CanonProof`'s doc forbids.

  It sits in the OTP root's boundary because that is the only layer whose deps already span the six
  domains involved. The one it does NOT reach directly is `Fleet.Workflow` (not a dep of the root):
  the card guards read it, so they are driven through `Fleet.Pilot.Application.verify_cards_and_roles!/1`,
  which keeps the workflow catalogue on Pilot's side of the boundary.

  ## What it does NOT check, and why the difference must be stated

  It covers the CATALOGUE, never the DEPLOYMENT. The boot also guards the forge base_url, tokens and
  credentials — configuration of a running fleet, not properties of a catalogue. A verifier that
  refused a good catalogue on a machine with no forge would send the operator to the wrong fix, so
  those guards are deliberately absent here.

  And it proves a DIRECTORY taken whole, where the boot proves the deployment's actual ASSEMBLY —
  fine per-tree overrides included (`:fleet_cap_profile, :root_dir` and its siblings keep
  precedence). An operator who panachages — this root plus a fine key pointing elsewhere — can get a
  green verify and a red boot with no check differing: the two simply do not read the same
  assembly. `verify/1` therefore returns the root it read and a note that it ignores fine overrides,
  and the CLI prints them as a header. That header is the whole defence against the false green.

  ## Runs in a STANDALONE process only

  Publishing the images writes process-global `:persistent_term`. This is written for a `mix` task
  or a release `eval` — an ephemeral VM that exits right after — never the live node, whose running
  images it would replace. A TEST driving it restores image state on exit, like `Fleet.CatalogueTest`.

  **Last revised**: 2026-08-01
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
