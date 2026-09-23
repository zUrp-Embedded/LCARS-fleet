defmodule Fleet.Project.GitOpsCommitterTest do
  @moduledoc """
  Who commits: the resolved human by default, the author itself for an act of the system.
  """
  use ExUnit.Case, async: true

  alias Fleet.Project.GitOps

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    {_, 0} = System.cmd("git", ["init", "-q", dir])
    File.write!(Path.join(dir, "f"), "x\n")
    {_, 0} = System.cmd("git", ["-C", dir, "add", "f"])
    %{dir: dir}
  end

  defp committer(dir) do
    {out, 0} = System.cmd("git", ["-C", dir, "log", "-1", "--format=%an <%ae> | %cn <%ce>"])
    String.trim(out)
  end

  test "`committer: :author` signs an act of the system on BOTH sides", %{dir: dir} do
    system = Fleet.Credentials.ForgeIdentity.system_identity()

    assert :ok =
             GitOps.run(["-C", dir, "commit", "-qm", "chore(import): init"],
               author: system,
               committer: :author
             )

    assert committer(dir) ==
             "#{system.name} <#{system.email}> | #{system.name} <#{system.email}>"
  end

  test "without it, the committer is the resolved HUMAN — never Git's own login@hostname", %{
    dir: dir
  } do
    {:ok, human} = Fleet.Credentials.ForgeIdentity.human_identity()
    system = Fleet.Credentials.ForgeIdentity.system_identity()

    assert :ok = GitOps.run(["-C", dir, "commit", "-qm", "x"], author: system)
    assert committer(dir) =~ "| #{human.name} <#{human.email}>"
  end
end
