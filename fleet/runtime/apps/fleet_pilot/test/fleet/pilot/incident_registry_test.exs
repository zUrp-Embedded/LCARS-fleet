defmodule Fleet.Pilot.IncidentRegistryTest do
  use ExUnit.Case, async: true

  alias Fleet.Pilot.IncidentRegistry, as: Reg

  describe "signature/3" do
    test "normalise les chiffres du subject + catégorise le reason (atom + tuple)" do
      assert Reg.signature("wake", "issue-42-engineer", :not_found) ==
               "wake:issue-N-engineer:not_found"

      assert Reg.signature("wake", "gatekeeper-permanent", {:send_keys_failed, :detail}) ==
               "wake:gatekeeper-permanent:send_keys_failed"
    end
  end

  describe "owner résilient (GenServer)" do
    @describetag :tmp_dir

    defp start_reg(tmp, extra) do
      name = :"reg_#{System.unique_integer([:positive])}"

      opts =
        [
          name: name,
          wal_path: Path.join(tmp, "incidents.json"),
          sync_debounce_ms: 5,
          retry_ms: 50
        ] ++ extra

      start_supervised!({Reg, opts})
      name
    end

    test "note → :ok, seen_before? = lookup mémoire, WAL local écrit, sync forge async", %{
      tmp_dir: tmp
    } do
      pid = self()

      name =
        start_reg(tmp,
          get_file_fun: fn _r, _p, _o -> {:error, :not_found} end,
          put_file_fun: fn _r, _p, content, _o -> send(pid, {:put, content}) && {:ok, "c"} end
        )

      refute Reg.seen_before?("wake:p:dead", server: name)
      assert :ok = Reg.note("wake:p:dead", :dead, server: name, now: "2026-06-20T10:00:00Z")
      assert Reg.seen_before?("wake:p:dead", server: name)

      # WAL local crash-survivable, écrit AVANT la forge
      assert {:ok, content} = File.read(Path.join(tmp, "incidents.json"))

      assert {:ok, %{"wake:p:dead" => %{"count" => 1, "last_reason" => ":dead"}}} =
               JSON.decode(content)

      # sync forge déclenché en async (débounce 5ms)
      assert_receive {:put, _}, 1000
    end

    test "boot : merge WAL local ∪ forge (les 2 sources de vérité)", %{tmp_dir: tmp} do
      File.write!(
        Path.join(tmp, "incidents.json"),
        JSON.encode!(%{"wake:a:x" => %{"count" => 1}})
      )

      name =
        start_reg(tmp,
          get_file_fun: fn _r, _p, _o ->
            {:ok, %{content: JSON.encode!(%{"wake:b:y" => %{"count" => 1}}), sha: "s"}}
          end,
          put_file_fun: fn _r, _p, _c, _o -> {:ok, "c"} end
        )

      assert Reg.seen_before?("wake:a:x", server: name)
      assert Reg.seen_before?("wake:b:y", server: name)
    end

    test "forge down : note reste :ok + WAL tient (fail-loud, AUCUNE perte)", %{tmp_dir: tmp} do
      name =
        start_reg(tmp,
          get_file_fun: fn _r, _p, _o -> {:error, :not_found} end,
          put_file_fun: fn _r, _p, _c, _o -> {:error, :forge_down} end
        )

      assert :ok = Reg.note("wake:p:x", :x, server: name, now: "2026-06-20T10:00:00Z")
      # mémoire OK malgré la forge KO (check récurrence ne dépend PAS de la forge)
      assert Reg.seen_before?("wake:p:x", server: name)
      # WAL tient → re-sync au retour de la forge
      assert {:ok, content} = File.read(Path.join(tmp, "incidents.json"))
      assert {:ok, %{"wake:p:x" => _}} = JSON.decode(content)
    end

    test "sync : merge bidirectionnel (incident d'une autre machine absorbé)", %{tmp_dir: tmp} do
      pid = self()

      name =
        start_reg(tmp,
          # la forge a un incident d'une AUTRE machine, pas encore connu localement
          get_file_fun: fn _r, _p, _o ->
            {:ok, %{content: JSON.encode!(%{"wake:other:z" => %{"count" => 2}}), sha: "s"}}
          end,
          put_file_fun: fn _r, _p, content, _o -> send(pid, {:put, content}) && {:ok, "c"} end
        )

      assert :ok = Reg.note("wake:local:q", :q, server: name, now: "2026-06-20T11:00:00Z")
      assert_receive {:put, content}, 1000
      # le put porte le MERGE (local + autre machine), pas un écrasement
      assert {:ok, merged} = JSON.decode(content)
      assert Map.has_key?(merged, "wake:local:q")
      assert Map.has_key?(merged, "wake:other:z")
      # et l'owner a adopté la vérité cross-machine
      assert Reg.seen_before?("wake:other:z", server: name)
    end

    test "record_or_escalate : jamais vu → noté (:recorded)", %{tmp_dir: tmp} do
      pid = self()

      name =
        start_reg(tmp,
          get_file_fun: fn _r, _p, _o -> {:error, :not_found} end,
          put_file_fun: fn _r, _p, content, _o -> send(pid, {:put, content}) && {:ok, "c"} end
        )

      assert :recorded =
               Reg.record_or_escalate("pod", "issue-9-engineer", :launch_failed,
                 server: name,
                 now: "2026-06-20T10:00:00Z"
               )

      assert Reg.seen_before?(Reg.signature("pod", "issue-9-engineer", :launch_failed),
               server: name
             )

      assert_receive {:put, _}, 1000
    end

    test "record_or_escalate : déjà vu → escalade (:escalated)", %{tmp_dir: tmp} do
      pid = self()
      sig = Reg.signature("pod", "issue-7-engineer", :result_timeout)

      name =
        start_reg(tmp,
          get_file_fun: fn _r, _p, _o ->
            {:ok, %{content: JSON.encode!(%{sig => %{"count" => 1}}), sha: "s"}}
          end,
          put_file_fun: fn _r, _p, _c, _o -> {:ok, "c"} end
        )

      assert {:escalated, :result_timeout} =
               Reg.record_or_escalate("pod", "issue-7-engineer", :result_timeout,
                 server: name,
                 create_issue_fun: fn repo, title, _b, iopts ->
                   send(pid, {:issue, repo, title, iopts}) && {:ok, 1}
                 end
               )

      assert_received {:issue, "fleet/lcars", title, iopts}
      assert title =~ "récurrence"
      assert iopts[:labels] == ["error_system"]
    end
  end
end
