defmodule Fleet.Pilot.CompletionOutboxTest do
  @moduledoc """
  Exercises JSON journal retention, deletion and corrupt/temporary file handling.
  No process crash, completion chain replay, concurrent writer or disk durability is tested.
  """
  use ExUnit.Case, async: false

  alias Fleet.Pilot.CompletionOutbox

  setup do
    root = Fleet.TestEnv.tmp_path("outbox-test")
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
      # Do not invent a key that could merge distinct completions.
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
      # Retain the corrupt artifact for diagnosis.
      assert File.exists?(corrompue)
    end

    # Tests exclusion of .tmp files, not atomicity under crashes or concurrent writes.
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
