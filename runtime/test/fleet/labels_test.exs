defmodule Fleet.LabelsTest do
  use ExUnit.Case, async: true

  alias Fleet.Labels

  # Protocol spellings must agree across producers and consumers.
  describe "protocol vocabulary (canon values)" do
    test "lock labels" do
      assert Labels.in_flight() == "lcars-in-flight"
      assert Labels.awaits_arch() == "lcars-awaits-arch"
    end
  end

  describe "wait/* — la cinquième famille (BL-6-48, pas 1)" do
    test "les CINQ raisons qui méritent un label, et elles sont scopées (donc exclusives)" do
      assert Labels.wait_for(:at_capacity) == "wait/capacity"
      assert Labels.wait_for(:role_busy) == "wait/role"
      assert Labels.wait_for(:draining) == "wait/draining"
      assert Labels.wait_for(:criterion_unavailable) == "wait/criterion"
      assert Labels.wait_for(:ci_pending) == "wait/ci"

      # Forge.Client uses / to set exclusive at label creation; this checks naming, not server state.
      for r <- [:at_capacity, :role_busy, :draining, :criterion_unavailable, :ci_pending] do
        assert String.starts_with?(Labels.wait_for(r), Labels.wait_prefix())
        assert String.contains?(Labels.wait_for(r), "/")
      end
    end

    test "les DOUZE silences sont NOMMÉS un par un — un nil par décision n'est pas un nil par oubli" do
      # These nils are policy choices documented beside their clauses.
      for reason <- [
            # déjà porté par un label existant → une seconde vérité
            :in_flight,
            :awaits_arch,
            # panne de config, pas attente → rail d'incident (BL-6-47.2)
            :no_role,
            # pas notre ticket
            :not_fleet_branch,
            # transitions et terminaux
            :onboarded,
            :merged,
            {:cancelled, 7},
            # escalades DÉJÀ résolues (elles posent `lcars-awaits-arch` elles-mêmes)
            {:rework_exhausted_escalated, 7},
            {:merge_blocked_escalated, 7},
            {:publish_brake_escalated, 7},
            # provenance failure already carries a forge trace
            {:head_read_failed, :timeout},
            # `draft` — arbitrage user en attente, DEUX formes, silencieuses en attendant
            :draft
          ] do
        assert Labels.wait_for(reason) == nil, "#{inspect(reason)} devrait rester silencieux"
      end

      assert Labels.wait_for({:draft, 7}) == nil
    end

    # Scan literal skipped tuples, Admission.refuse calls and dispatcher skip decisions.
    # Limit the last form to step_dispatcher: step_run_consumer has an unrelated completion
    # vocabulary. These textual patterns cover known shapes, not arbitrary computed reasons.
    @skip_producer_patterns [
      ~r/\{:skipped,\s*(:[a-z_]+|\{:[a-z_]+)/,
      ~r/Admission\.refuse\(\s*(:[a-z_]+|\{:[a-z_]+)/
    ]
    @decide_skip_file "lib/fleet/pilot/step_dispatcher.ex"
    @decide_skip_pattern ~r/\{:skip,\s*(:[a-z_]+|\{:[a-z_]+)/

    defp reasons_produced_in_lib do
      from_all = "lib/**/*.ex" |> Path.wildcard() |> Enum.flat_map(&reasons_in_file/1)

      from_decide =
        @decide_skip_file
        |> File.read!()
        |> then(&Regex.scan(@decide_skip_pattern, &1))
        |> Enum.map(fn [_, r] -> r end)

      (from_all ++ from_decide) |> Enum.uniq() |> Enum.sort()
    end

    defp reasons_in_file(path) do
      body = File.read!(path)

      Enum.flat_map(@skip_producer_patterns, fn rx ->
        rx |> Regex.scan(body) |> Enum.map(fn [_, r] -> r end)
      end)
    end

    # `":foo"` → l'atome ; `"{:foo"` → la forme tuple, sondée avec un argument quelconque.
    defp probe_of("{" <> _ = raw), do: {String.to_atom(String.trim_leading(raw, "{:")), :probe}
    defp probe_of(raw), do: String.to_atom(String.trim_leading(raw, ":"))

    defp in_table?(raw) do
      _ = Labels.wait_for(probe_of(raw))
      true
    rescue
      ArgumentError -> false
    end

    test "MUR D'EXHAUSTIVITÉ : toute raison présente dans `lib/` est connue de la table" do
      reasons = reasons_produced_in_lib()

      # Guard the scanner against succeeding with an empty or drastically reduced corpus.
      assert length(reasons) >= 18,
             "le motif ne trouve que #{length(reasons)} raisons — l'instrument est cassé, " <>
               "pas le code (mesuré : 20 le 2026-08-03, sur les trois formes de producteur)"

      inconnues = Enum.reject(reasons, &in_table?/1)

      assert inconnues == [],
             "raisons de skip présentes dans lib/ et ABSENTES de la table BL-6-48 : " <>
               "#{inspect(inconnues)} — chacune doit recevoir un label OU un nil argumenté"
    end

    test "MUR INVERSE : toute entrée de la table a un producteur dans `lib/`" do
      # The reverse check catches table entries whose producers disappeared.
      produced = MapSet.new(reasons_produced_in_lib())

      table =
        "lib/fleet/labels.ex"
        |> File.read!()
        |> then(&Regex.scan(~r/def wait_for\((:[a-z_]+|\{:[a-z_]+)/, &1))
        |> Enum.map(fn [_, r] -> r end)
        |> Enum.uniq()
        |> Enum.sort()

      assert length(table) >= 18,
             "la table ne rend que #{length(table)} entrées — l'instrument est cassé " <>
               "(mesuré : 20 le 2026-08-03)"

      orphelines = Enum.reject(table, &MapSet.member?(produced, &1))

      assert orphelines == [],
             "entrées de la table BL-6-48 SANS producteur dans lib/ : #{inspect(orphelines)} — " <>
               "soit la raison est produite, soit elle sort de la table. Pas de troisième option."
    end

    test "une raison INCONNUE lève — elle ne naît pas muette" do
      assert_raise ArgumentError, ~r/absent from the BL-6-48 table/, fn ->
        Labels.wait_for(:une_raison_qui_nexiste_pas)
      end
    end
  end
end
