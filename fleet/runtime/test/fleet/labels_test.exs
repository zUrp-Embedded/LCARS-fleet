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

    test "MUR D'EXHAUSTIVITÉ : toute raison présente dans `lib/` est connue de la table" do
      # LE test de cet item. Il ne redit pas la table — il MESURE le code, parce qu'une table qui se
      # relit elle-même ne protège de rien. La v1 du plan annonçait 11 raisons ; il y en avait 17,
      # et les six manquantes étaient des TUPLES qu'un motif limité aux atomes ne pouvait pas voir.
      # Une des six avait été écrite une heure plus tôt par la même main.
      #
      # Le motif ci-dessous capture LES DEUX FORMES, délibérément. C'est la correction de l'erreur
      # qui a produit ce test.
      rx = ~r/\{:skipped,\s*(:[a-z_]+|\{:[a-z_]+)/

      reasons =
        Path.wildcard("lib/**/*.ex")
        |> Enum.flat_map(fn path ->
          path |> File.read!() |> then(&Regex.scan(rx, &1)) |> Enum.map(fn [_, r] -> r end)
        end)
        |> Enum.uniq()
        |> Enum.sort()

      # Garde-fou sur l'instrument lui-même : s'il ne trouve plus rien, c'est LUI qui est cassé, pas
      # le code qui serait devenu propre. Un mur qui ne mesure rien passe toujours.
      assert length(reasons) >= 15,
             "le motif ne trouve que #{length(reasons)} raisons — l'instrument est cassé, " <>
               "pas le code (mesuré : 17 le 2026-08-03)"

      inconnues =
        Enum.reject(reasons, fn raw ->
          # `":foo"` → l'atome ; `"{:foo"` → la forme tuple, sondée avec un argument quelconque.
          probe =
            if String.starts_with?(raw, "{"),
              do: {String.to_atom(String.trim_leading(raw, "{:")), :probe},
              else: String.to_atom(String.trim_leading(raw, ":"))

          try do
            _ = Labels.wait_for(probe)
            true
          rescue
            ArgumentError -> false
          end
        end)

      assert inconnues == [],
             "raisons de skip présentes dans lib/ et ABSENTES de la table BL-6-48 : " <>
               "#{inspect(inconnues)} — chacune doit recevoir un label OU un nil argumenté"
    end

    test "une raison INCONNUE lève — elle ne naît pas muette" do
      # Le fallthrough silencieux est la façon dont la dix-huitième raison passerait inaperçue.
      assert_raise ArgumentError, ~r/absent from the BL-6-48 table/, fn ->
        Labels.wait_for(:une_raison_qui_nexiste_pas)
      end
    end
  end
end
