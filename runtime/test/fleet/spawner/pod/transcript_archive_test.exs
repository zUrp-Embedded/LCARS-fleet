defmodule Fleet.Spawner.Pod.TranscriptArchiveTest do
  @moduledoc """
  A pod's transcripts survive the removal of its directory, within a bounded archive.
  Serialized: the archive root and bound are application-wide settings.
  """
  use ExUnit.Case, async: false

  alias Fleet.Spawner.Pod.{StateFs, TranscriptArchive}

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    root = Path.join(tmp, "archive")
    Fleet.TestEnv.put_env_restoring(:lcars_fleet, :spawner_transcript_archive_root, root)
    %{root: root}
  end

  defp pod_with_transcripts(tmp, name) do
    pod_dir = Path.join([tmp, "pods", name])
    proj = Path.join([pod_dir, ".claude", "projects", "-home-basilisk"])
    File.mkdir_p!(proj)
    File.write!(Path.join(proj, "2badcafe.jsonl"), ~s({"type":"user"}\n))
    File.write!(Path.join(proj, "1badcafe.jsonl.dead"), ~s({"type":"old"}\n))
    pod_dir
  end

  test "the live session and its .dead predecessor are kept, under the pod's name", %{
    tmp_dir: tmp,
    root: root
  } do
    pod_dir = pod_with_transcripts(tmp, "pod_fleet-basilisk-issue-17-engineer")
    assert :ok = TranscriptArchive.archive(pod_dir)

    [kept] = Path.wildcard(Path.join(root, "pod_fleet-basilisk-issue-17-engineer-*"))
    assert File.read!(Path.join(kept, "2badcafe.jsonl")) =~ "user"
    assert File.exists?(Path.join(kept, "1badcafe.jsonl.dead"))
  end

  test "removing a terminal pod ARCHIVES its transcripts before its directory goes", %{
    tmp_dir: tmp,
    root: root
  } do
    pod_dir = pod_with_transcripts(tmp, "pod_x")
    state_dir = Path.join(tmp, "state/pod_x")
    File.mkdir_p!(state_dir)

    StateFs.rm_terminal_artifacts(state_dir, pod_dir,
      pod_dir_root: Path.join(tmp, "pods"),
      state_fs_root: Path.join(tmp, "state")
    )

    assert [_] = Path.wildcard(Path.join(root, "pod_x-*"))
  end

  test "the archive is BOUNDED: beyond the limit the oldest go", %{tmp_dir: tmp, root: root} do
    Fleet.TestEnv.put_env_restoring(:lcars_fleet, :spawner_transcript_archive_max, 2)

    for n <- 1..3 do
      TranscriptArchive.archive(pod_with_transcripts(tmp, "pod_#{n}"))
      # distinct modification times, oldest first
      Process.sleep(1100)
    end

    names = root |> File.ls!() |> Enum.map(&String.replace(&1, ~r/-\d.*$/, "")) |> Enum.sort()
    assert names == ["pod_2", "pod_3"]
  end

  test "a pod with no transcript writes nothing", %{tmp_dir: tmp, root: root} do
    empty = Path.join(tmp, "pods/pod_empty")
    File.mkdir_p!(empty)
    assert :ok = TranscriptArchive.archive(empty)
    refute File.exists?(root)
  end
end
