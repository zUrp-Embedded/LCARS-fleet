defmodule Fleet.Pilot.CompletionOutboxTest do
  @moduledoc """
  6-127 — LE RESULTAT DE L'AGENT SURVIT A LA MORT DE LA CHAINE DE COMPLETION.

  Ce que la fiche vise n'est pas l'idempotence — elle EXISTE deja, concue et documentee dans le
  `@moduledoc` de `StepRunCompleter` (verrou leve EN DERNIER, ecritures rejouables, « recovery
  replays the sequence, the done steps skip »). Ce qui manquait est le REJOUEUR, et une copie
  durable du resultat a rejouer : `TaskQueue` marque l'item `completed` des que la diffusion locale
  rend `:ok`, donc la charge utile est la SEULE copie du travail de l'agent quand la chaine
  demarre. Une Task qui meurt l'emportait, le poller reclamait l'orphelin, et un agent REFAISAIT le
  travail — ce que la preuve de sortie interdit explicitement.

  Les trois points de mort que la fiche nomme (avant push, apres push avant PR, apres PR avant
  unlock) sont tous DANS la chaine : ils se simulent par un completer qui leve a l'etape voulue.
  """
  use ExUnit.Case, async: false

  alias Fleet.Pilot.CompletionOutbox

  setup do
    root = Path.join(System.tmp_dir!(), "outbox-test-#{System.unique_integer([:positive])}")
    Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_completion_outbox_root, root)
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, root: root}
  end

  defp payload(id) do
    %{
      "work_item_id" => id,
      "issue_id" => "42",
      "role" => "engineer",
      "repo" => "o/r",
      "result" => %{"answer" => "le travail de l'agent"}
    }
  end

  describe "le journal lui-meme" do
    test "pose, relit a l'identique, retire" do
      assert {:ok, "wi-1"} = CompletionOutbox.put(payload("wi-1"))

      assert [%{"work_item_id" => "wi-1", "result" => %{"answer" => texte}}] =
               CompletionOutbox.pending()

      assert texte == "le travail de l'agent"

      assert :ok = CompletionOutbox.delete("wi-1")
      assert CompletionOutbox.pending() == []
    end

    test "le retrait est IDEMPOTENT — une entree deja partie n'est pas une erreur" do
      assert {:ok, _} = CompletionOutbox.put(payload("wi-2"))
      assert :ok = CompletionOutbox.delete("wi-2")
      assert :ok = CompletionOutbox.delete("wi-2")
    end

    test "SANS `work_item_id` on ne fabrique PAS d'identite" do
      # Une cle inventee ferait dedupliquer deux completions distinctes. L'appelant continue sans
      # journal — le comportement d'avant 6-127, borne et nomme.
      assert {:error, :no_work_item_id} = CompletionOutbox.put(%{"issue_id" => "42"})
      assert {:error, :no_work_item_id} = CompletionOutbox.put(payload(""))
      assert CompletionOutbox.pending() == []
    end

    test "un journal absent n'est pas une erreur — il n'y a simplement rien de du" do
      assert CompletionOutbox.pending() == []
    end

    test "une entree ILLISIBLE est signalee et CONSERVEE, jamais sautee en silence", %{root: root} do
      assert {:ok, _} = CompletionOutbox.put(payload("wi-bon"))
      File.mkdir_p!(root)
      corrompue = Path.join(root, "wi-casse.json")
      File.write!(corrompue, "{ceci n'est pas du json")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert [%{"work_item_id" => "wi-bon"}] = CompletionOutbox.pending()
        end)

      assert log =~ "entree ILLISIBLE"
      # Elle reste : c'est la seule piece a conviction d'un resultat d'agent qu'on ne saura pas
      # reprendre. L'effacer detruirait la trace du probleme avec le probleme.
      assert File.exists?(corrompue)
    end

    # TEMOIN — sans lui, une ecriture qui ne produit jamais de `.json` passerait tous les tests
    # ci-dessus (ils ne liraient que ce qu'ils viennent d'ecrire), et un fichier temporaire
    # abandonne serait relu comme une completion due.
    test "TEMOIN — l'ecriture est atomique : aucun `.tmp` n'est jamais rendu par `pending/0`", %{
      root: root
    } do
      assert {:ok, _} = CompletionOutbox.put(payload("wi-3"))
      File.write!(Path.join(root, "wi-orphelin.json.tmp"), ~s({"work_item_id":"wi-orphelin"}))

      cles = CompletionOutbox.pending() |> Enum.map(& &1["work_item_id"])
      assert cles == ["wi-3"]
    end
  end
end
