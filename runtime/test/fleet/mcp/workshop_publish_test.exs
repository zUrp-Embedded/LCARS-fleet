defmodule Fleet.MCP.WorkshopPublishTest do
  @moduledoc """
  Publication of the workshop face over a real local Git repository with a bare `origin`.

  WHAT THESE WITNESSES CLOSE. A pod never pushes, and until this delegation nothing published that
  face on purpose: a document reached the forge only when swept along by the next scratchpad note,
  under that note's message — or never (measured 2026-09-16 on the bench, where two documents were
  carried by a `chore(scratch)` commit). What is measured here: the face is staged and pushed, the
  commit carries the SYSTEM identity on both sides so the next delivery from that face is not
  refused, a clean face publishes nothing and says so, and the receipt names what Git staged.
  """
  use ExUnit.Case, async: false

  alias Fleet.Credentials.ForgeIdentity

  alias Fleet.MCP.PodTools.Delegation.Workshop

  @repo "fleet/demo"

  setup do
    tmp = Fleet.TestEnv.tmp_path("workshop-publish")
    root = Path.join(tmp, "workshop")
    dir = Path.join(root, "demo")
    bare = Path.join(tmp, "origin.git")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(tmp) end)

    {_, 0} = git(["init", "-q", "--bare", "-b", "workshop", bare])
    {_, 0} = git(["init", "-q", "-b", "workshop", dir])
    {_, 0} = g(dir, ["config", "user.email", "lcars@machine"])
    {_, 0} = g(dir, ["config", "user.name", "lcars"])
    {_, 0} = g(dir, ["remote", "add", "origin", bare])
    File.write!(Path.join(dir, "README.md"), "atelier\n")
    {_, 0} = g(dir, ["add", "."])
    {_, 0} = g(dir, ["commit", "-q", "-m", "base"])
    {_, 0} = g(dir, ["push", "-q", "origin", "HEAD:workshop"])

    Fleet.TestEnv.put_env_restoring(:lcars_fleet, :mcp_pod_resolver, fn _ ->
      {:ok, %{role: "architect", repo: @repo}}
    end)

    Fleet.TestEnv.put_env_restoring(:lcars_fleet, :mcp_workshop_root, root)

    %{dir: dir, bare: bare}
  end

  defp git(args), do: System.cmd("git", args, stderr_to_stdout: true)
  defp g(dir, args), do: git(["-C", dir] ++ args)

  defp publish(message),
    do: Workshop.publish(%{pod_id: "pod-arch", role: "architect", repo: @repo}, message)

  defp log(dir, format, ref \\ "HEAD") do
    {out, 0} = g(dir, ["log", "-1", "--format=" <> format, ref])
    String.trim(out)
  end

  test "un document ecrit dans l'atelier part sur la forge, sous le message du pod", %{
    dir: dir,
    bare: bare
  } do
    File.mkdir_p!(Path.join(dir, "plans"))
    File.write!(Path.join([dir, "plans", "T0.md"]), "# decoupage\n")

    assert {:ok, recu} = publish("cadrage: plan de decoupage T0")
    assert recu["published"] == true
    assert recu["pushed"] == true
    assert "plans/T0.md" in recu["files"]

    assert log(dir, "%s") == "cadrage: plan de decoupage T0"
    # la forge porte le meme commit : la publication est ce qui est mesure, pas l'intention
    {out, 0} = git(["-C", bare, "log", "-1", "--format=%H", "workshop"])
    assert String.trim(out) == recu["commit"]
  end

  test "le commit porte l'identite du systeme des DEUX cotes — sinon la prochaine livraison depuis cette face est refusee",
       %{dir: dir} do
    File.write!(Path.join(dir, "backlog.md"), "- un item\n")

    assert {:ok, _} = publish("backlog: premier jet")

    systeme = ForgeIdentity.system_email()
    assert log(dir, "%ae") == systeme
    assert log(dir, "%ce") == systeme

    # et la garde du livrable ne le juge pas comme l'identite d'un producteur
    base = log(dir, "%H", "HEAD~1")

    assert :ok =
             Fleet.Workflow.DeliverableGate.check_identity(dir, base, ["engineer@lcars.local"])
  end

  test "le trailer dit QUI a ecrit, la signature dit que c'est le systeme qui publie", %{dir: dir} do
    File.write!(Path.join(dir, "spec.md"), "# spec\n")

    assert {:ok, _} = publish("spec: premier jet")

    {out, 0} = g(dir, ["log", "-1", "--format=%(trailers:key=Co-authored-by,valueonly)"])
    assert String.trim(out) =~ "LCARS-architect"
  end

  test "une face propre ne publie rien, et le dit — c'est un etat, pas un echec", %{dir: dir} do
    assert {:ok, recu} = publish("rien a dire")
    assert recu["published"] == false
    assert recu["why"] =~ "rien à publier"
    # aucun commit n'est fabrique pour le plaisir de repondre
    assert log(dir, "%s") == "base"
  end

  test "un message vide est refuse avant toute ecriture", %{dir: dir} do
    File.write!(Path.join(dir, "note.md"), "x\n")

    assert {:error, :message_empty} = publish("   ")
    assert log(dir, "%s") == "base"
  end

  test "une face absente est un refus nomme, jamais un dossier fabrique", %{dir: dir} do
    File.rm_rf!(dir)

    assert {:error, {:no_workshop_face, chemin}} = publish("peu importe")
    assert chemin =~ "demo"
    refute File.dir?(dir)
  end

  test "un pod sans capacite de delegation est refuse par la porte, avant toute lecture" do
    Fleet.TestEnv.put_env_restoring(:lcars_fleet, :mcp_pod_resolver, fn _ ->
      {:ok, %{role: "engineer", repo: @repo}}
    end)

    assert {:error, :forbidden_not_architect} = publish("tentative")
  end
end
