defmodule Fleet.Test.BizCatalogueFixture do
  @moduledoc """
  Writes a second catalogue, `biz`, whose judge is absent from the bundled catalogue:
  resolving its card in the wrong root cannot accidentally find the same role.

  The caller sets `:catalogue_install_dirs` to `[install_dir]`, then calls
  `Fleet.CapProfile.Image.publish!/0` and `Fleet.Workflow.Loader.publish_image!/0`.
  On exit, call `Fleet.CapProfile.Image.unpublish/0` and
  `Fleet.Workflow.Loader.unpublish_all_images/0`: persistent images outlive the test.
  Callers use `async: false` because these settings and images are global.
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

    # A project default with no jury makes a mistaken fallback from the engraved card observable.
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

    # Both jury and CI differ from no-jury, exposing inconsistent card resolution.
    File.write!(Path.join(cards, "strict.yaml"), """
    kind: WorkflowMap
    metadata:
      name: strict
      description: "carte metier stricte"
    spec:
      jury: [#{@judge}]
      ci: required
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
