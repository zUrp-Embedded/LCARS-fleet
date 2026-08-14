defmodule Fleet.Shutdown.QuiesceTest do
  # async: false — global :persistent_term flag. on_exit resume! IMPERATIVE:
  # a leaked quiescing=true would break every downstream start_pipeline test.
  use ExUnit.Case, async: false

  alias Fleet.Shutdown.Quiesce

  setup do
    on_exit(&Quiesce.resume!/0)
    :ok
  end

  test "default: not quiescing" do
    Quiesce.resume!()
    refute Quiesce.quiescing?()
  end

  test "refuse! → quiescing? true (idempotent) ; resume! → false" do
    assert :ok = Quiesce.refuse!()
    assert Quiesce.quiescing?()
    assert :ok = Quiesce.refuse!()
    assert Quiesce.quiescing?()
    assert :ok = Quiesce.resume!()
    refute Quiesce.quiescing?()
  end

  describe "busy/1 — the synchronous-finalizer counter the drain sums" do
    test "counts up inside the wrap, back down after — nested wraps stack" do
      base = Quiesce.busy_count()

      Quiesce.busy(fn ->
        assert Quiesce.busy_count() == base + 1

        Quiesce.busy(fn ->
          assert Quiesce.busy_count() == base + 2
        end)

        assert Quiesce.busy_count() == base + 1
      end)

      assert Quiesce.busy_count() == base
    end

    test "a raising finalizer still decrements (a crash must never freeze the drain)" do
      base = Quiesce.busy_count()

      assert_raise RuntimeError, fn ->
        Quiesce.busy(fn -> raise "finalizer crashed" end)
      end

      assert Quiesce.busy_count() == base
    end

    test "busy/1 returns the fun's result" do
      assert Quiesce.busy(fn -> {:ok, :done} end) == {:ok, :done}
    end
  end

  # 6-007 — LE CLAMP EFFACAIT LA SEULE OBSERVATION QUI TIRAIT QUELQUE CHOSE DU `signed: true`.
  # Le compteur est cree signe — donc capable de descendre sous zero — et lu via `max(0, …)`, ce qui
  # rend un desequilibre `add`/`sub` INDETECTABLE : le compteur ment durablement sans rien signaler.
  # Le clamp reste (un solde negatif veut dire « rien en vol », ce que le drain doit conclure), mais
  # il n'est plus la seule reponse.
  describe "6-007 — un solde negatif est SIGNALE, jamais efface en silence" do
    setup do
      # ⚠ LES DEUX SLOTS, et le second est celui qu'on oublie. Le ref vit en `:persistent_term` pour
      # tout le VM : le compteur (1) ET le plancher deja signale (2) survivent d'un test a l'autre.
      # Ne remettre a zero que le compteur laissait un plancher de -7 pose par un voisin, et le test
      # d'a cote — qui force -3 — devenait MUET par construction. L'ordre des tests etant aleatoire,
      # ca rougissait un test sur deux : un defaut de mise en scene, pas du sujet.
      Quiesce.init_busy!()
      ref = :persistent_term.get({Quiesce, :busy})
      reset = fn -> :atomics.put(ref, 1, 0) && :atomics.put(ref, 2, 0) end
      reset.()
      on_exit(reset)
      {:ok, ref: ref}
    end

    test "solde negatif -> `error` qui nomme l'ecart, et busy_count rend toujours 0", %{ref: ref} do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          :atomics.put(ref, 1, -3)
          assert Quiesce.busy_count() == 0
        end)

      assert log =~ "busy_count NEGATIF (-3)"

      # La trace doit dire ce que le drain fait MALGRE l'anomalie, sinon elle transforme une reponse
      # correcte en panique.
      assert log =~ "rien en vol"
      assert log =~ "FAUX de 3"
    end

    test "UNE ligne par nouveau plancher, pas une par appel", %{ref: ref} do
      # `busy_count/0` alimente la somme d'en-vol du drain, sur une boucle de POLL : journaliser a
      # chaque lecture noierait le drain sous une anomalie deja permanente.
      premier =
        ExUnit.CaptureLog.capture_log(fn ->
          :atomics.put(ref, 1, -1)
          for _ <- 1..5, do: assert(Quiesce.busy_count() == 0)
        end)

      assert premier =~ "NEGATIF (-1)"
      assert length(String.split(premier, "busy_count NEGATIF")) == 2, "une seule ligne attendue"

      # Un plancher PLUS BAS est une anomalie nouvelle : elle parle.
      plus_bas =
        ExUnit.CaptureLog.capture_log(fn ->
          :atomics.put(ref, 1, -7)
          assert Quiesce.busy_count() == 0
        end)

      assert plus_bas =~ "NEGATIF (-7)"

      # Un plancher MOINS bas ne re-parle pas : c'est la meme anomalie, vue moins profondement.
      remonte =
        ExUnit.CaptureLog.capture_log(fn ->
          :atomics.put(ref, 1, -2)
          assert Quiesce.busy_count() == 0
        end)

      refute remonte =~ "busy_count NEGATIF"
    end

    test "TEMOIN — un compteur sain reste MUET et compte juste" do
      # Sans lui, un report inconditionnel passerait les tests ci-dessus et remplirait le drain de
      # lignes d'erreur sur un fonctionnement nominal — les ticks nominaux sont silencieux.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert Quiesce.busy_count() == 0

          assert Quiesce.busy(fn -> Quiesce.busy_count() end) == 1
        end)

      refute log =~ "NEGATIF"
    end
  end
end
