defmodule Fleet.Pilot.IncidentRegistryTest do
  use ExUnit.Case, async: true

  alias Fleet.Pilot.IncidentRegistry, as: Reg

  describe "signature/3" do
    test "normalise les chiffres du subject + catégorise le reason (atom + tuple)" do
      assert Reg.signature("wake", "issue-42-engineer", :not_found) ==
               "wake:issue-N-engineer:not_found"

      assert Reg.signature("wake", "gatekeeper", {:send_keys_failed, :detail}) ==
               "wake:gatekeeper:send_keys_failed"
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

    test "WAL multi-ligne : un incident par ligne (diff git lisible), reste JSON valide",
         %{tmp_dir: tmp} do
      name =
        start_reg(tmp,
          get_file_fun: fn _r, _p, _o -> {:error, :not_found} end,
          put_file_fun: fn _r, _p, _c, _o -> {:ok, "c"} end
        )

      assert :ok = Reg.note("wake:a:1", :dead, server: name, now: "2026-06-20T10:00:00Z")
      assert :ok = Reg.note("wake:b:2", :dead, server: name, now: "2026-06-20T10:01:00Z")

      assert {:ok, content} = File.read(Path.join(tmp, "incidents.json"))

      # 2 incidents → 4 lignes (`{`, incident a, incident b, `}`) : UN incident par ligne. Mord si on
      # revient au `JSON.encode!` compact (qui collerait tout sur une ligne → diff git illisible).
      lines = content |> String.trim_trailing() |> String.split("\n")
      assert length(lines) == 4
      assert hd(lines) == "{"
      assert List.last(lines) == "}"
      assert Enum.any?(lines, &String.starts_with?(&1, ~s(  "wake:a:1":)))
      assert Enum.any?(lines, &String.starts_with?(&1, ~s(  "wake:b:2":)))

      # ...et reste un JSON valide : `decode/1` relit les deux incidents tels quels.
      assert {:ok, %{"wake:a:1" => _, "wake:b:2" => _}} = JSON.decode(content)
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

      # Retour = le NUMÉRO du issue (1, rendu par le stub), pas le reason : un `{:escalated, num}` PROUVE
      # qu'un issue existe vraiment. (Avant le fix d'honnêteté, le retour portait le reason et sortait même
      # quand l'ouverture du issue échouait — cf. le test « forge DOWN » ci-dessous.)
      # MÉCANIQUE (fix F-RUN-2 2026-07-04) : `create_issue` reçoit l'assignee mais AUCUN label (le POST
      # Gitea exige des IDs entiers, pas des noms → 422) ; le label `error_system` est posé APRÈS via
      # `add_label` par NOM. On vérifie les DEUX appels.
      assert {:escalated, 1} =
               Reg.record_or_escalate("pod", "issue-7-engineer", :result_timeout,
                 server: name,
                 create_issue_fun: fn repo, title, _b, iopts ->
                   send(pid, {:issue, repo, title, iopts}) && {:ok, 1}
                 end,
                 add_label_fun: fn repo, num, lbl, _o ->
                   send(pid, {:label, repo, num, lbl}) && {:ok, :added}
                 end
               )

      assert_received {:issue, "fleet/lcars", title, iopts}
      assert title =~ "récurrence"
      # create_issue NE porte PLUS de label (sinon 422) — assignee seulement.
      refute Keyword.has_key?(iopts, :labels)
      assert iopts[:assignees] == ["starfleet"]
      # Le label durable est posé par NOM sur l'issue créée.
      assert_received {:label, "fleet/lcars", 1, "error_system"}
    end

    test "record_or_escalate : déjà vu + forge DOWN → {:escalation_failed,_}, JAMAIS {:escalated} (aucun issue)",
         %{tmp_dir: tmp} do
      sig = Reg.signature("pod", "issue-7-engineer", :result_timeout)

      name =
        start_reg(tmp,
          get_file_fun: fn _r, _p, _o ->
            {:ok, %{content: JSON.encode!(%{sig => %{"count" => 1}}), sha: "s"}}
          end,
          put_file_fun: fn _r, _p, _c, _o -> {:ok, "c"} end
        )

      # `create_issue` échoue aux DEUX tentatives (avec assignee, puis fallback label-only) = forge down.
      # Le retour doit DIRE l'échec — surtout pas un `{:escalated, _}` rassurant alors qu'aucun issue
      # sysadmin n'a été ouvert.
      assert {:escalation_failed, :forge_down} =
               Reg.record_or_escalate("pod", "issue-7-engineer", :result_timeout,
                 server: name,
                 create_issue_fun: fn _r, _t, _b, _o -> {:error, :forge_down} end
               )
    end

    test "record_or_escalate escalate_kind :sp_suspect → issue pointe le SP (wake récurrent)", %{
      tmp_dir: tmp
    } do
      pid = self()
      sig = Reg.signature("wake", "issue-7-engineer", {:no_ack, :wake})

      name =
        start_reg(tmp,
          get_file_fun: fn _r, _p, _o ->
            {:ok, %{content: JSON.encode!(%{sig => %{"count" => 1}}), sha: "s"}}
          end,
          put_file_fun: fn _r, _p, _c, _o -> {:ok, "c"} end
        )

      assert {:escalated, _} =
               Reg.record_or_escalate("wake", "issue-7-engineer", {:no_ack, :wake},
                 server: name,
                 escalate_kind: :sp_suspect,
                 pane: "ECRAN-TEST-42 : derniere ligne REPL",
                 create_issue_fun: fn _r, title, body, _o ->
                   send(pid, {:issue, title, body}) && {:ok, 1}
                 end,
                 add_label_fun: fn _r, _n, _l, _o -> {:ok, :added} end
               )

      assert_received {:issue, title, body}
      assert title =~ "SP suspect"
      assert body =~ "PROMPT"
      # [5] : l'écran capturé (fallback-ack déporté) est attaché au issue
      assert body =~ "ECRAN-TEST-42"
      assert body =~ "Écran capturé"
    end
  end
end
