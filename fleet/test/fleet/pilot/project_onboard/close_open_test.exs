defmodule Fleet.Pilot.ProjectOnboard.CloseOpenTest do
  @moduledoc """
  `close_project/2` + `open/2`'s unpark half (BL-6-30) — the fixture is built by the REAL
  `onboard/2` (dirs whose git origin PROVES the project), the forge issue side is a recording
  stub holding its state in the process dictionary (the verbs run in the caller's process).
  The parked STATE is asserted on what the stub forge holds — the marker issues — never on
  the verbs' return alone.
  """
  use ExUnit.Case, async: false

  alias Fleet.Pilot.ProjectOnboard

  @moduletag :tmp_dir

  # Same on-disk file:// forge shape as the sibling suites (repo ops only).
  defmodule FileForge do
    def generate_repo(_template, _name, _opts), do: {:error, :template_missing}

    def create_repo(name, _opts) do
      root = Process.get(:file_forge_root)
      src = Path.join(root, "_src_#{name}_#{System.unique_integer([:positive])}")
      bare = Path.join([root, "fleet", "#{name}.git"])
      File.mkdir_p!(src)
      File.mkdir_p!(Path.dirname(bare))

      {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", src], stderr_to_stdout: true)
      File.write!(Path.join(src, "SEED"), "seed")
      {_, 0} = System.cmd("git", ["-C", src, "add", "."], stderr_to_stdout: true)

      {_, 0} =
        System.cmd(
          "git",
          ["-C", src, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "init"],
          stderr_to_stdout: true
        )

      {_, 0} = System.cmd("git", ["clone", "-q", "--bare", src, bare], stderr_to_stdout: true)
      {:ok, "fleet/#{name}"}
    end

    def protect_branch(_repo, _rule, _fc), do: {:ok, :created}

    def default_branch(full_name, _fc) do
      if File.dir?(bare_path(full_name)), do: {:ok, "main"}, else: {:error, {:http, 404, "gone"}}
    end

    def delete_repo(full_name, _fc) do
      File.rm_rf!(bare_path(full_name))
      :ok
    end

    def branch_exists?(full_name, branch, _fc) do
      path = bare_path(full_name)

      File.dir?(path) and
        match?(
          {_, 0},
          System.cmd(
            "git",
            ["-C", path, "rev-parse", "--verify", "--quiet", "refs/heads/#{branch}"],
            stderr_to_stdout: true
          )
        )
    end

    defp bare_path(full_name), do: Path.join(Process.get(:file_forge_root), "#{full_name}.git")
  end

  defmodule Humans do
    def user_exists?(_h, _fc), do: {:ok, true}
    def team_member?(_org, _team, _h, _fc), do: {:ok, true}
  end

  # Issue-side forge (the `:forge_issues` seam): the OPEN issues live in the process dictionary
  # — a marker created is a marker the next read SEES (the state round-trips, unlike a static
  # stub). Degradations driven by pdict flags.
  defmodule IssueForge do
    def list_open_issues(_repo, _opts) do
      Process.get(:issue_list_result, {:ok, Process.get(:issues, [])})
    end

    def create_issue(repo, title, body, opts) do
      n = (Process.get(:issue_seq) || 0) + 1
      Process.put(:issue_seq, n)
      Process.put(:issues, Process.get(:issues, []) ++ [%{"number" => n, "title" => title}])
      send(self(), {:issue_created, repo, n, title, body, opts})
      {:ok, n}
    end

    def close_issue(repo, n, _opts) do
      if Process.get(:issue_close_fails) do
        {:error, :forge_down}
      else
        Process.put(:issues, Enum.reject(Process.get(:issues, []), &(&1["number"] == n)))
        send(self(), {:issue_closed, repo, n})
        {:ok, %{}}
      end
    end
  end

  # Spawner stub: records kill_pod (the architect stop) — the pod never exists → :not_found,
  # which close maps to :none (best-effort semantics under test is the CALL, not the outcome).
  defmodule StubSpawner do
    def kill_pod(pod_id) do
      send(self(), {:killed, pod_id})
      {:error, :not_found}
    end
  end

  defp opts(tmp) do
    forge_root = Path.join(tmp, "forge")
    File.mkdir_p!(forge_root)
    Process.put(:file_forge_root, forge_root)

    [
      projects_root: Path.join(tmp, "projects"),
      work_root: Path.join(tmp, "work"),
      doc_root: Path.join(tmp, "doc"),
      base_url: "file://" <> forge_root,
      forge_repo: FileForge,
      forge_users: Humans,
      forge_issues: IssueForge,
      spawner: StubSpawner,
      sleeper: fn _ms -> :ok end,
      ensure_labels: fn _repo, _o -> :ok end,
      ensure_architect: fn repo, _o ->
        send(self(), {:arch_ensured, repo})
        {:ok, "arch-stub"}
      end
    ]
  end

  defp marker_titles do
    Process.get(:issues, []) |> Enum.map(& &1["title"])
  end

  setup %{tmp_dir: tmp} do
    o = opts(tmp)
    assert {:ok, %{repo: "fleet/pong"}} = ProjectOnboard.onboard("pong", o)
    # Drop the onboarding's own arch-ensure signal — the tests below assert the verbs'.
    receive do
      {:arch_ensured, _} -> :ok
    after
      0 -> :ok
    end

    {:ok, o: o}
  end

  test "close: marker posted (parked title, human assignee) THEN architect stopped", %{o: o} do
    assert {:ok, %{outcome: :closed, marker_issue: 1, architect: :none}} =
             ProjectOnboard.close_project("fleet/pong", o)

    assert_received {:issue_created, "fleet/pong", 1, title, body, issue_opts}
    assert Fleet.Forge.Protocol.parked_issue_title?(title)
    # Assignee = the human (the poller's assigned_by scoping must SEE the marker).
    assert [_human] = issue_opts[:assignees]
    # The body documents BOTH reopening paths (UI-close is a designed unpark).
    assert body =~ "open_project"
    assert body =~ "fermer CE ticket"

    # Marker BEFORE stop: the kill signal arrives after the create (mailbox order).
    assert_received {:killed, _pod_id}
  end

  test "close is convergent: already parked → honest no-op, no second marker, stop retried",
       %{o: o} do
    assert {:ok, %{outcome: :closed}} = ProjectOnboard.close_project("fleet/pong", o)
    assert_received {:killed, _}

    assert {:ok, %{outcome: :already_closed}} = ProjectOnboard.close_project("fleet/pong", o)
    # ONE marker on the forge, not two.
    assert [_only_one] = marker_titles()
    # A prior close that crashed between marker and stop is repaired here: the stop re-runs.
    assert_received {:killed, _}
  end

  test "close: unreadable parked state REFUSES (never a blind double-marker)", %{o: o} do
    Process.put(:issue_list_result, {:error, :forge_down})

    assert {:error, {:close_failed, {:parked_state_unreadable, :forge_down}}} =
             ProjectOnboard.close_project("fleet/pong", o)

    refute_received {:issue_created, _, _, _, _, _}
    refute_received {:killed, _}
  end

  test "close: a project not on the machine is refused", %{o: o} do
    assert {:error, {:not_on_machine, "fleet/ghost"}} =
             ProjectOnboard.close_project("fleet/ghost", o)

    refute_received {:issue_created, _, _, _, _, _}
  end

  test "open: a project whose DOC face is missing is NOT on the machine", %{o: o} do
    # `open` is what hands a project to the architect, whose producer path is on `doc`. Dropping
    # the doc face from the on-machine check left the whole suite green (measured 2026-08-08):
    # every fixture here is a fully onboarded project, so a two-face check and a three-face one
    # answer identically. Opening a project without its doc face succeeds and then wedges at the
    # first documentary ticket, far from the cause — which is the shape of failure the guard
    # exists to prevent, not a new one.
    assert {:ok, _} = ProjectOnboard.close_project("fleet/pong", o)
    File.rm_rf!(Path.join(o[:doc_root], "pong"))

    assert {:error, {:not_on_machine, "fleet/pong"}} = ProjectOnboard.open("fleet/pong", o)
    refute_received {:arch_ensured, _}
  end

  test "open: unparks (ALL markers closed) then ensures the architect", %{o: o} do
    assert {:ok, _} = ProjectOnboard.close_project("fleet/pong", o)
    # A concurrent close can legitimately leave a second marker — open must clear BOTH.
    Process.put(
      :issues,
      Process.get(:issues, []) ++
        [%{"number" => 99, "title" => Fleet.Forge.Protocol.parked_issue_title()}]
    )

    assert {:ok, %{repo: "fleet/pong", architect: arch}} = ProjectOnboard.open("fleet/pong", o)
    assert arch.status == "up"

    assert_received {:issue_closed, "fleet/pong", 1}
    assert_received {:issue_closed, "fleet/pong", 99}
    assert marker_titles() == []
    assert_received {:arch_ensured, "fleet/pong"}
  end

  test "open: unreadable parked state is a WALL — no architect over an unknown rail", %{o: o} do
    Process.put(:issue_list_result, {:error, :forge_down})

    assert {:error, {:unpark_failed, {:parked_state_unreadable, :forge_down}}} =
             ProjectOnboard.open("fleet/pong", o)

    refute_received {:arch_ensured, _}
  end

  test "open: a marker that will not close is a WALL — never a live arch on a parked rail",
       %{o: o} do
    assert {:ok, _} = ProjectOnboard.close_project("fleet/pong", o)
    Process.put(:issue_close_fails, true)

    assert {:error, {:unpark_failed, {1, :forge_down}}} = ProjectOnboard.open("fleet/pong", o)
    refute_received {:arch_ensured, _}
    # The marker still holds the state on the forge.
    assert [_still_there] = marker_titles()
  end

  test "open without a marker: zero forge write beyond the read — historical contract intact",
       %{o: o} do
    assert {:ok, _} = ProjectOnboard.open("fleet/pong", o)
    refute_received {:issue_closed, _, _}
    assert_received {:arch_ensured, "fleet/pong"}
  end
end
