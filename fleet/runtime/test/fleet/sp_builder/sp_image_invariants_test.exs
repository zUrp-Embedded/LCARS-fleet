defmodule Fleet.SPBuilder.SpImageInvariantsTest do
  @moduledoc """
  Invariants over the COMPOSED SP images — the finished prompt each role actually receives
  (role base + default modops + subagent template), not the fragments.

  The blocks have a no-drift gate, but nothing analyzed the FINAL image: two fragments can each be
  fine and their concatenation still carry two contradictory doctrines (a judge told to diff a git
  ref that does not exist in its clone, an architect promising a validation chain the engine does
  not run, a bundle ordering an operation of a retired architecture). These tests compose the REAL
  canon images and refuse the known contradiction classes — purely NEGATIVE invariants (no prose is
  pinned; the SP package stays the operator's to write).
  """
  use ExUnit.Case, async: true

  @judges ~w(reviewer qualifier)

  # Retired-dialect registry: identifiers of ARCHITECTURES THAT NO LONGER EXIST, refused in any
  # composed image / active bundle. Grows one entry per retirement; never shrinks silently.
  # Each entry: {label, regex} — label names the retirement for the failure message.
  @retired_dialect [
    {"cycle_regime (retired cap-profile field)", ~r/cycle_regime/},
    {"L-scale intensity levels (current scheme is C0..C4)", ~r/\bL[0-9]\+?\b/},
    {"implementer as a CAP-PROFILE (retired role — the SUBAGENT template is current)",
     ~r/cap-profile\s*:?\s+implementer/i},
    {"workers M2 architecture doc (retired)", ~r/workers M2/},
    {"audits/*.json review rail (retired — verdicts go through the forge review)",
     ~r/audits\/[a-zA-Z0-9_{}-]+\.json/}
  ]

  # The FULL image a pod actually receives = the role draft (`agent-<role>-base.md`, projected by
  # the spawner's Assets rail) + the composed overlay (modops + subagent template, SPBuilder). The
  # canon profiles carry no `systemPrompt` — analyzing the compose output alone would MISS the role
  # base entirely (and pass vacuously, as this test's first draft did).
  defp composed_image(role) do
    {:ok, profile} = Fleet.CapProfile.load(role)
    defaults = Fleet.CapProfile.default_modops(profile)
    {:ok, %{sp_md: overlay}} = Fleet.SPBuilder.compose(profile, defaults)

    draft =
      Application.app_dir(
        :lcars_fleet,
        "priv/catalogue/sp_builder/sp_drafts/agent-#{role}-base.md"
      )
      |> File.read!()

    draft <> "\n" <> overlay
  end

  describe "judge images (reviewer/qualifier) — one doctrine, executable on THIS architecture" do
    test "every git range is origin-anchored: the local ref `main` DOES NOT EXIST in a judge's clone" do
      # The judge's clone is mono-branch: the base is `origin/main` (the drafts state it
      # themselves). A composed image instructing `diff main..HEAD` sends the judge against an
      # absent ref — it errors, or silently reviews the wrong base.
      for role <- @judges do
        image = composed_image(role)

        bare_main = Regex.scan(~r/(?<!origin\/)\bmain\.\.\.?/, image)

        assert bare_main == [],
               "#{role}: composed image instructs a git range on the LOCAL ref `main` " <>
                 "(#{inspect(bare_main)}) — that ref does not exist in the judge's mono-branch " <>
                 "clone; every range must anchor on origin/main"
      end
    end

    test "no retired dialect in a judge's composed image" do
      for role <- @judges, {label, re} <- @retired_dialect do
        image = composed_image(role)

        refute Regex.match?(re, image),
               "#{role}: composed image speaks a retired dialect — #{label}"
      end
    end
  end

  describe "architect image — the card is the authority, the prompt promises no chain" do
    test "no hardcoded validation chain (role→…→role): a C0/C1/audit-only card runs a DIFFERENT one" do
      # The engine runs the workflow CARD; an SP promising `engineer → judges → gatekeeper` as THE
      # chain misrepresents to the human every delegation whose card differs (the human overestimates
      # the proofs behind a delivery). The prompt must not name a fixed chain — the effective card is
      # data (list_workflow_cards / the engraved route), not prose.
      image = composed_image("architect")

      # Spans sentence-internal newlines (prose wraps); stops at a sentence end — a chain promise
      # is one sentence naming roles joined by arrows.
      chains = Regex.scan(~r/engineer[^.]{0,200}(?:→|->)[^.]{0,300}gatekeeper/su, image)

      assert chains == [],
             "architect: composed image hardcodes a validation chain #{inspect(chains)} — " <>
               "the workflow card is the authority, the prompt must not promise a fixed chain"
    end
  end

  describe "active modop bundles — only doctrine executable on the CURRENT architecture is activable" do
    # Same computation as the consumption test: activable = union of every canon cap-profile's
    # modop_set default ∪ optional. Orphans (nothing can activate them) are out of scope here.
    test "no retired dialect in any ACTIVE bundle's sp.md" do
      canon = Application.app_dir(:lcars_fleet, "priv/catalogue/cap_profile/canon")

      referenced =
        Path.join([canon, "cap-profiles", "*.yaml"])
        |> Path.wildcard()
        |> Enum.flat_map(fn f ->
          case YamlElixir.read_from_file(f) do
            {:ok, %{"spec" => %{"modop_set" => ms}}} when is_map(ms) ->
              List.wrap(ms["default"]) ++ List.wrap(ms["optional"])

            _ ->
              []
          end
        end)
        |> Enum.uniq()

      assert referenced != [], "no active bundles resolved — canon unreadable?"

      for bundle <- referenced,
          path = Path.join([canon, "modop-bundles", bundle, "sp.md"]),
          File.exists?(path),
          {label, re} <- @retired_dialect do
        content = File.read!(path)

        refute Regex.match?(re, content),
               "active bundle #{bundle}: sp.md speaks a retired dialect — #{label} " <>
                 "(an activation could order an operation impossible on the current architecture)"
      end
    end
  end
end
