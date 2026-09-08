defmodule Fleet.LabelsTest do
  use ExUnit.Case, async: true

  alias Fleet.Labels

  # These values ARE the forge-state-machine wire-protocol (DN §5). A rename must be a
  # DELIBERATE, visible act (this test going red forces it) — poller/dispatcher/completer/consumer
  # agree on them to the byte. Single source F072.
  describe "protocol vocabulary (canon values)" do
    # #5.2 D4 — `dispatched` (legacy poller lock) + the `state:*` chain (state-in-label) removed;
    # only the LOCKS remain.
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

      # Le `/` n'est pas cosmétique : `ensure_repo_label` crée `exclusive: true` sur un nom qui en
      # contient un. C'est LUI qui rend deux attentes simultanées irreprésentables, sans code de
      # garde. Un `wait-capacity` plat casserait la famille en silence.
      for r <- [:at_capacity, :role_busy, :draining, :criterion_unavailable, :ci_pending] do
        assert String.starts_with?(Labels.wait_for(r), Labels.wait_prefix())
        assert String.contains?(Labels.wait_for(r), "/")
      end
    end

    test "les DOUZE silences sont NOMMÉS un par un — un nil par décision n'est pas un nil par oubli" do
      # Chacun a sa raison dans le code ; ce test existe pour qu'un lecteur ne les prenne pas pour
      # autant d'oublis et n'ajoute pas douze labels.
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
            # mur de provenance : sa trace forge existe depuis `d31ed188a`
            {:head_read_failed, :timeout},
            # `draft` — arbitrage user en attente, DEUX formes, silencieuses en attendant
            :draft
          ] do
        assert Labels.wait_for(reason) == nil, "#{inspect(reason)} devrait rester silencieux"
      end

      assert Labels.wait_for({:draft, 7}) == nil
    end

    # Les raisons de skip atteignent `wait_for/1` sous TROIS formes, et le mur n'en voyait qu'une.
    # `{:skipped, X}` est la forme littérale. `Admission.refuse(X, …)` est arrivée avec l'entonnoir
    # (les refus du bail passent la raison en atome nu, jamais dans un tuple). `{:skip, X}` est la
    # décision de `decide/1`, convertie en `{:skipped, reason}` par une VARIABLE — donc invisible à
    # tout motif littéral.
    #
    # Le troisième motif est limité à `step_dispatcher.ex` À DESSEIN : l'arbre porte DEUX
    # vocabulaires `{:skip, _}` distincts, et celui de `step_run_consumer` (rail de complétion) ne
    # rejoint jamais la table. L'élargir sans cette borne exigerait des entrées de table pour des
    # raisons qui n'attendent rien.
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

    # Les raisons produites par UN fichier, tous motifs confondus.
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
      # LE test de cet item. Il ne redit pas la table — il MESURE le code, parce qu'une table qui se
      # relit elle-même ne protège de rien. La v1 du plan annonçait 11 raisons ; il y en avait 17,
      # et les six manquantes étaient des TUPLES qu'un motif limité aux atomes ne pouvait pas voir.
      # Une des six avait été écrite une heure plus tôt par la même main.
      reasons = reasons_produced_in_lib()

      # Garde-fou sur l'instrument lui-même : s'il ne trouve plus rien, c'est LUI qui est cassé, pas
      # le code qui serait devenu propre. Un mur qui ne mesure rien passe toujours.
      assert length(reasons) >= 18,
             "le motif ne trouve que #{length(reasons)} raisons — l'instrument est cassé, " <>
               "pas le code (mesuré : 20 le 2026-08-03, sur les trois formes de producteur)"

      inconnues = Enum.reject(reasons, &in_table?/1)

      assert inconnues == [],
             "raisons de skip présentes dans lib/ et ABSENTES de la table BL-6-48 : " <>
               "#{inspect(inconnues)} — chacune doit recevoir un label OU un nil argumenté"
    end

    test "MUR INVERSE : toute entrée de la table a un producteur dans `lib/`" do
      # L'autre sens, et il manquait. Le mur d'exhaustivité est UNIDIRECTIONNEL : il attrape une
      # raison née muette, jamais une entrée qui a survécu à son producteur. Une entrée orpheline ne
      # casse rien — elle décrit un état que la fleet ne peut plus atteindre, et c'est exactement
      # « l'interface qui ment » : quelqu'un lit la table pour savoir ce que la fleet fait, et y
      # trouve un `wait/*` que plus rien ne pose.
      #
      # Le cas n'est pas théorique : le plan de ce chantier annonçait la disparition du producteur
      # unique de `:at_capacity` avec la suppression du cap global. Elle n'a pas eu lieu — l'entonnoir
      # lui en avait donné un autre entre-temps — mais rien dans l'arbre n'aurait su le dire.
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
      # Le fallthrough silencieux est la façon dont la dix-huitième raison passerait inaperçue.
      assert_raise ArgumentError, ~r/absent from the BL-6-48 table/, fn ->
        Labels.wait_for(:une_raison_qui_nexiste_pas)
      end
    end
  end
end
