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

  describe "seen_before?/2" do
    test "true si la signature est présente, false sinon" do
      reg = %{"wake:p:not_found" => %{"count" => 1}}
      opts = [get_file_fun: fn _r, _p, _o -> {:ok, %{content: JSON.encode!(reg), sha: "s"}} end]

      assert Reg.seen_before?("wake:p:not_found", opts)
      refute Reg.seen_before?("wake:p:autre", opts)
    end

    test "fail-open : registre illisible → false (pas de fausse escalade)" do
      opts = [get_file_fun: fn _r, _p, _o -> {:error, :not_found} end]
      refute Reg.seen_before?("wake:p:x", opts)
    end
  end

  describe "note/3" do
    test "nouvelle signature → count 1 + first/last_seen, commit AVEC sha (update)" do
      pid = self()

      opts = [
        get_file_fun: fn _r, _p, _o -> {:ok, %{content: JSON.encode!(%{}), sha: "sha-1"}} end,
        put_file_fun: fn _r, _p, content, o -> send(pid, {:put, content, o}) && {:ok, "new"} end,
        now: "2026-06-20T10:00:00Z"
      ]

      assert :ok = Reg.note("wake:p:not_found", :not_found, opts)
      assert_received {:put, content, put_opts}
      assert put_opts[:sha] == "sha-1"

      assert {:ok,
              %{
                "wake:p:not_found" => %{
                  "count" => 1,
                  "first_seen" => "2026-06-20T10:00:00Z",
                  "last_seen" => "2026-06-20T10:00:00Z",
                  "last_reason" => ":not_found"
                }
              }} = JSON.decode(content)
    end

    test "signature existante → count incrémenté, last_seen maj, first_seen conservé" do
      pid = self()

      existing = %{
        "wake:p:x" => %{
          "count" => 1,
          "first_seen" => "2026-06-19T00:00:00Z",
          "last_seen" => "2026-06-19T00:00:00Z"
        }
      }

      opts = [
        get_file_fun: fn _r, _p, _o -> {:ok, %{content: JSON.encode!(existing), sha: "s"}} end,
        put_file_fun: fn _r, _p, content, _o -> send(pid, {:put, content}) && {:ok, "x"} end,
        now: "2026-06-20T12:00:00Z"
      ]

      assert :ok = Reg.note("wake:p:x", :x, opts)
      assert_received {:put, content}

      assert {:ok,
              %{
                "wake:p:x" => %{
                  "count" => 2,
                  "first_seen" => "2026-06-19T00:00:00Z",
                  "last_seen" => "2026-06-20T12:00:00Z"
                }
              }} = JSON.decode(content)
    end

    test "registre absent (404) → le crée, commit SANS sha (create)" do
      pid = self()

      opts = [
        get_file_fun: fn _r, _p, _o -> {:error, :not_found} end,
        put_file_fun: fn _r, _p, content, o -> send(pid, {:put, content, o}) && {:ok, "new"} end,
        now: "2026-06-20T10:00:00Z"
      ]

      assert :ok = Reg.note("wake:p:x", :x, opts)
      assert_received {:put, _content, put_opts}
      assert put_opts[:sha] == nil
    end

    test "écriture échoue → {:error} (best-effort)" do
      opts = [
        get_file_fun: fn _r, _p, _o -> {:ok, %{content: JSON.encode!(%{}), sha: "s"}} end,
        put_file_fun: fn _r, _p, _c, _o -> {:error, :boom} end,
        now: "2026-06-20T10:00:00Z"
      ]

      assert {:error, :boom} = Reg.note("wake:p:x", :x, opts)
    end
  end
end
