defmodule Mix.Tasks.Lcars.ProvenanceVerifyTest do
  @moduledoc """
  L'ENVELOPPE de `mix lcars.provenance.verify`, pas la logique du verificateur.

  La logique vit dans `Fleet.Workflow.Provenance.Verifier` (92 % couvert). Ce que personne ne
  mesurait, et qui MENTAIT : l'usage et le moduledoc disaient `--work-root` et `--projects-root`,
  le parseur n'acceptait que `--ops-root` et `--code-root`, et une option inconnue etait jetee en
  silence — l'operateur qui tapait ce que la doc lui disait voyait la tache verifier les racines
  par DEFAUT en pretendant avoir lu les siennes. Trouve en ecrivant ce fichier (2026-09-12).

  Decision 3 du lot E6, option B (`42-DECISIONS.md`).

  async: false — `Mix.shell/1` est global au noeud.
  """
  use ExUnit.Case, async: false

  alias Mix.Tasks.Lcars.Provenance.Verify

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    :ok
  end

  defp mix_said(acc \\ []) do
    receive do
      {:mix_shell, kind, [msg]} -> mix_said([{kind, msg} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # Un ops et un code fabriques, sous des racines que la tache recoit en options.
  defp racines(fichiers_ops) do
    base = Fleet.TestEnv.tmp_path("provenance_verify")
    on_exit(fn -> File.rm_rf!(base) end)
    ops = Path.join(base, "ops")
    code = Path.join(base, "code")
    File.mkdir_p!(Path.join(ops, "demo"))
    File.mkdir_p!(Path.join(code, "demo"))

    for {rel, contenu} <- fichiers_ops do
      chemin = Path.join([ops, "demo", rel])
      File.mkdir_p!(Path.dirname(chemin))
      File.write!(chemin, contenu)
    end

    {ops, code}
  end

  describe "le NOM de la commande" do
    test "`mix lcars.provenance.verify` resout vers CE module" do
      assert Mix.Task.get("lcars.provenance.verify") == Verify
      assert Mix.Task.task_name(Verify) == "lcars.provenance.verify"
    end
  end

  describe "l'usage — et il nomme les options que le parseur ACCEPTE" do
    test "aucun argument → Mix.raise avec l'usage" do
      assert_raise Mix.Error, ~r/usage: mix lcars\.provenance\.verify <project-name>/, fn ->
        Verify.run([])
      end
    end

    test "⚠ l'usage, le moduledoc et le parseur disent les MEMES noms d'options" do
      # La faute mesuree : deux noms documentes, deux autres acceptes. Ce temoin lit les trois
      # sources et exige l'accord — ce n'est pas la valeur qu'il epingle, c'est l'ACCORD.
      usage = assert_raise(Mix.Error, fn -> Verify.run([]) end).message
      {:docs_v1, _, _, _, %{"en" => doc}, _, _} = Code.fetch_docs(Verify)

      for opt <- ["--ops-root", "--code-root"] do
        assert usage =~ opt, "l'usage ne nomme pas #{opt}"
        assert doc =~ opt, "le moduledoc ne nomme pas #{opt}"
      end

      refute doc =~ "--work-root"
      refute doc =~ "--projects-root"
    end

    test "une option INCONNUE est refusee et nommee — celle que l'ancienne doc conseillait" do
      assert_raise Mix.Error, ~r/option\(s\) inconnue\(s\) : --work-root/, fn ->
        Verify.run(["demo", "--work-root", "/x"])
      end
    end
  end

  describe "les racines" do
    test "un ops absent est refuse en le nommant, AVANT de regarder le code" do
      {ops, code} = racines([])
      File.rm_rf!(Path.join(ops, "demo"))

      assert_raise Mix.Error, ~r/ops repo not found: .*ops\/demo/, fn ->
        Verify.run(["demo", "--ops-root", ops, "--code-root", code])
      end
    end

    test "un code absent est refuse en le nommant" do
      {ops, code} = racines([])
      File.rm_rf!(Path.join(code, "demo"))

      assert_raise Mix.Error, ~r/code repo not found: .*code\/demo/, fn ->
        Verify.run(["demo", "--ops-root", ops, "--code-root", code])
      end
    end

    test "aucun enonce de provenance : la tache le DIT, elle ne rend pas un vert muet" do
      {ops, code} = racines([])
      assert :ok = Verify.run(["demo", "--ops-root", ops, "--code-root", code])
      assert [{:info, msg}] = mix_said()
      assert msg =~ "no statement"
    end

    test "un enonce qui ne tient pas fait echouer la tache, en comptant" do
      {ops, code} = racines([{"provenance/a.json", "{not json"}])

      assert_raise Mix.Error, ~r/provenance verification FAILED \(1 statement\(s\)\)/, fn ->
        Verify.run(["demo", "--ops-root", ops, "--code-root", code])
      end

      said = mix_said()
      assert Enum.any?(said, fn {_, msg} -> msg =~ "FAIL" and msg =~ "provenance/a.json" end)
      assert Enum.any?(said, fn {_, msg} -> msg =~ "0 ok, 1 fail" end)
    end
  end
end
