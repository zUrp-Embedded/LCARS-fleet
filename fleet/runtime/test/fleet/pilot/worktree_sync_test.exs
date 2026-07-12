defmodule Fleet.Pilot.WorktreeSyncTest do
  @moduledoc """
  `WorktreeSync` aligne RÉELLEMENT le clone local sur `origin/main` — git réel (origin bare local +
  clone + avancement), pas un stub. C'est l'anti-vert-creux du fix : sans alignement, le fichier livré
  n'apparaît jamais sur le disque (le bug d'origine). `origin` est un path local → pas de réseau, pas
  de token (le `fetch auth:true` traverse `ForgeAuth.git_env() == []` en test, inerte sur un remote local).
  """
  use ExUnit.Case, async: true

  alias Fleet.Pilot.WorktreeSync

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    # origin bare + un seed clone qui pose le 1er commit sur main (le « projet » de départ).
    origin = Path.join(tmp, "origin.git")
    seed = Path.join(tmp, "seed")
    git!(["init", "--bare", "-b", "main", origin])
    git!(["clone", origin, seed])
    git_in!(seed, ["config", "user.email", "t@lcars"])
    git_in!(seed, ["config", "user.name", "t"])
    commit_push!(seed, "README.md", "v0\n", "init")

    # le clone local = la vitrine `/home/projects/<name>`, figée au départ (comme à l'onboarding).
    root = Path.join(tmp, "projects")
    File.mkdir_p!(root)
    proj = Path.join(root, "myproj")
    git!(["clone", origin, proj])

    # nom unique → tests async sans collision sur le nom global du GenServer.
    name = :"wt_#{System.unique_integer([:positive])}"
    start_supervised!({WorktreeSync, name: name, projects_root: root})

    %{seed: seed, proj: proj, sync: name}
  end

  test "aligne le clone local sur origin/main après un avancement (le livrable arrive sur le disque)",
       %{seed: seed, proj: proj, sync: sync} do
    # origin avance (le « merge ») ; le clone local n'a encore RIEN (le bug : il reste figé).
    commit_push!(seed, "hello.sh", "echo hi\n", "feat: hello")
    refute File.exists?(Path.join(proj, "hello.sh"))

    assert :ok = WorktreeSync.sync_now(sync, "fleet/myproj")

    # APRÈS : le disque reflète origin/main — même SHA, fichier livré présent.
    assert File.exists?(Path.join(proj, "hello.sh"))
    assert head(proj) == head(seed)
  end

  test "clone local absent → :ok (best-effort, rien à aligner, le livrable reste sur la forge)",
       %{sync: sync} do
    assert :ok = WorktreeSync.sync_now(sync, "fleet/jamais-clone")
  end

  test "syncs concurrents sur le même worktree : sérialisés, tous :ok et clone aligné (pas d'index.lock)",
       %{seed: seed, proj: proj, sync: sync} do
    commit_push!(seed, "hello.sh", "echo hi\n", "feat: hello")

    results =
      1..6
      |> Enum.map(fn _ -> Task.async(fn -> WorktreeSync.sync_now(sync, "fleet/myproj") end) end)
      |> Task.await_many(30_000)

    # Le GenServer sérialise (un git à la fois) → six alignements concurrents ne se marchent pas dessus.
    assert Enum.all?(results, &(&1 == :ok))
    assert head(proj) == head(seed)
  end

  defp commit_push!(dir, file, content, msg) do
    File.write!(Path.join(dir, file), content)
    git_in!(dir, ["add", "-A"])
    git_in!(dir, ["commit", "-m", msg])
    git_in!(dir, ["push", "origin", "main"])
  end

  defp git!(args), do: {_, 0} = System.cmd("git", args, stderr_to_stdout: true)

  defp git_in!(dir, args),
    do: {_, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)

  defp head(dir),
    do: System.cmd("git", ["-C", dir, "rev-parse", "HEAD"]) |> elem(0) |> String.trim()
end
