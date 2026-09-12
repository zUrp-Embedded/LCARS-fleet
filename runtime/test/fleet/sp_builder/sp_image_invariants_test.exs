defmodule Fleet.SPBuilder.SpImageInvariantsTest do
  @moduledoc """
  Negative lexical checks over shipped role drafts plus default overlays, selected bundle
  files and worker protocols. They catch known contradictions across fragments without
  pinning replacement prose. This helper is not the complete launch composition: it does
  not append protocols, follow borrowed role drafts or exercise every catalogue scope.
  """
  use ExUnit.Case, async: true

  @judges ~w(reviewer qualifier)

  # Named regression patterns; review removals deliberately. Labels are historical test data
  # (including the stale claim that the implementer subagent template is current).
  @retired_dialect [
    {"cycle_regime (retired cap-profile field)", ~r/cycle_regime/},
    {"L-scale intensity levels (current scheme is C0..C4)", ~r/\bL[0-9]\+?\b/},
    {"implementer as a CAP-PROFILE (retired role — the SUBAGENT template is current)",
     ~r/cap-profile\s*:?\s+implementer/i},
    {"workers M2 architecture doc (retired)", ~r/workers M2/},
    {"audits/*.json review rail (retired — verdicts go through the forge review)",
     ~r/audits\/[a-zA-Z0-9_{}-]+\.json/}
  ]

  # Include the draft: checking compose/3 alone would miss the role's base instructions.
  defp composed_image(role) do
    {:ok, profile} = Fleet.CapProfile.load(role)
    defaults = Fleet.CapProfile.default_modops(profile)
    {:ok, %{sp_md: overlay}} = Fleet.SPBuilder.compose(profile, defaults)

    # Resolve across business/system rather than assuming every draft lives in business.
    draft = role |> Fleet.SPBuilder.sp_draft_path() |> File.read!()

    draft <> "\n" <> overlay
  end

  describe "judge images (reviewer/qualifier) — one doctrine, executable on THIS architecture" do
    test "every git range is origin-anchored: the local ref `main` DOES NOT EXIST in a judge's clone" do
      # Reject bare main ranges. The historical title/message overstate this check:
      # it neither requires origin/main nor verifies ref existence; bootstrap supplies lcars/base.
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
      # data (card_list / the engraved route), not prose.
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
    # Business YAML references only; malformed profiles and absent local bundle files are skipped.
    # Unlike the consumption suite, this does not enumerate the system root.
    test "no retired dialect in any ACTIVE bundle's sp.md" do
      canon = Application.app_dir(:lcars_fleet, "priv/catalogue/cap_profile")

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

  # Worker instructions must not deny the human protocol that Assets appends for interlocutor both.
  # These checks reject known exclusivity phrases without prescribing replacement prose.
  describe "6-138 — protocole `both` : la moitie worker ne nie plus la composition" do
    test "un role declare `both`, donc la negation d'exclusivite est une contradiction" do
      roots = ["priv/catalogue", "priv/catalogue-system"]

      both_roles =
        roots
        |> Enum.flat_map(&Path.wildcard(Path.join([&1, "cap_profile/cap-profiles", "*.yaml"])))
        |> Enum.filter(fn f ->
          case YamlElixir.read_from_file(f) do
            {:ok, %{"spec" => %{"interlocutor" => "both"}}} -> true
            _ -> false
          end
        end)
        |> Enum.map(&Path.basename(&1, ".yaml"))

      # Require a real both-role population so this regression cannot become vacuous.
      assert both_roles != [],
             "aucun role `interlocutor: both` — cet invariant ne mesure plus rien ; " <>
               "si le mode a ete retire, retirer aussi la composition dans `read_protocole_user/1`"

      worker =
        roots
        |> Enum.map(&Path.join(&1, "sp_builder/sp_drafts/protocole-user-worker.md"))
        |> Enum.filter(&File.regular?/1)

      assert worker != [], "aucun protocole worker trouve — instrument casse"

      for path <- worker do
        content = File.read!(path)

        refute content =~ ~r/ne cohabitent jamais/i,
               "#{path} nie la cohabitation alors que #{inspect(both_roles)} declare(nt) `both` — " <>
                 "le pod recoit les deux moities ET une phrase disant que la seconde n'existe pas"

        refute content =~ ~r/seul qui fasse autorit/i,
               "#{path} se declare seule autorite alors que #{inspect(both_roles)} declare(nt) " <>
                 "`both` : la moitie conversation est servie juste apres, dans le meme fichier"
      end
    end
  end
end
