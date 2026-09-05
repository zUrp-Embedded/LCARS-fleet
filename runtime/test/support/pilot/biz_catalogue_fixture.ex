defmodule Fleet.Test.BizCatalogueFixture do
  @moduledoc """
  A SECOND catalogue, `biz`, installed beside the bundled one and published into the images —
  the fixture behind every witness that a project reads the card of ITS catalogue and not the
  default image's. Its card `standard` names a judge that exists nowhere in the bundled catalogue,
  so a resolution in the wrong root has nothing to find: a role present on both sides would prove
  nothing.

  The fixture only WRITES the catalogue. Arming it is the caller's, in three lines, so this module
  needs no reach into the images (Boundary): declare the install dir
  (`Fleet.TestEnv.put_env_restoring(:lcars_fleet, :catalogue_install_dirs, [install_dir])`),
  publish both images (`Fleet.CapProfile.Image.publish!/0`, `Fleet.Workflow.Loader.publish_image!/0`)
  and, on exit, unpublish BOTH (`Fleet.CapProfile.Image.unpublish/0`,
  `Fleet.Workflow.Loader.unpublish_all_images/0` — a persistent image outlives the test). Global
  state: callers are `async: false`.
  """

  use Boundary, deps: [Fleet.Catalogue], exports: []

  @judge "code-reviewer"

  @doc """
  Declares project `name` under `code_root` with `card` as its pipeline default — the declaration
  `Fleet.Project.Roles.project_jury/2` reads.
  """
  @spec declare_project!(Path.t(), String.t(), String.t()) :: :ok
  def declare_project!(code_root, name, card) do
    File.mkdir_p!(Path.join(code_root, name))

    File.write!(
      Path.join([code_root, name, ".lcars.json"]),
      Jason.encode!(%{
        "pipeline_default" => card,
        "level" => "C0",
        "nature" => "fixture",
        "justification" => "test",
        "declared_by" => "test",
        "declared_at" => "2026-09-05"
      })
    )
  end

  @doc "The judge the `biz` card names; absent from the bundled catalogue on purpose."
  def judge, do: @judge

  @doc "Writes `biz` under `tmp`; returns the INSTALL dir (the parent the runtime scans) and the root."
  @spec write!(Path.t()) :: %{install_dir: Path.t(), root: Path.t()}
  def write!(tmp) do
    home = Path.join(tmp, "operator")
    biz = Path.join([home, "catalogues", "biz"])

    profiles = Path.join(biz, Fleet.Catalogue.rel(:cap_profiles))
    cards = Path.join(biz, Fleet.Catalogue.rel(:workflow_maps))
    File.mkdir_p!(profiles)
    File.mkdir_p!(cards)

    # A real canon judge, renamed: same schema, a name the bundled catalogue does not carry.
    canon = Path.join([:code.priv_dir(:lcars_fleet), "catalogue", "cap_profile", "cap-profiles"])

    File.read!(Path.join(canon, "reviewer.yaml"))
    |> String.replace("name: reviewer", "name: #{@judge}")
    |> then(&File.write!(Path.join(profiles, "#{@judge}.yaml"), &1))

    # And a worker for the step role — same treatment, same reason.
    File.read!(Path.join(canon, "engineer.yaml"))
    |> String.replace("name: engineer", "name: biz-dev")
    |> then(&File.write!(Path.join(profiles, "biz-dev.yaml"), &1))

    File.write!(Path.join(cards, "standard.yaml"), """
    kind: WorkflowMap
    metadata:
      name: standard
      description: "carte du catalogue metier"
    spec:
      jury: [#{@judge}]
      ci: ignore
      max_rework_rounds: 1
      steps:
        build:
          role: biz-dev
          needs: []
          inputs:
            - ticket.body
    """)

    # A second card, judged by NOBODY: the witnesses declare it as the PROJECT card so that a rail
    # falling back to the project card (the engraved one unloadable in the wrong root) convenes
    # `[]` — observably not `[#{@judge}]`.
    File.write!(Path.join(cards, "no-jury.yaml"), """
    kind: WorkflowMap
    metadata:
      name: no-jury
      description: "carte metier sans jury"
    spec:
      jury: []
      ci: ignore
      max_rework_rounds: 1
      steps:
        build:
          role: biz-dev
          needs: []
          inputs:
            - ticket.body
    """)

    File.write!(
      Path.join(biz, "catalogue.yaml"),
      "api_version: 1\nname: biz\ndefault_card: standard\n"
    )

    %{install_dir: Path.join(home, "catalogues"), root: biz}
  end
end
