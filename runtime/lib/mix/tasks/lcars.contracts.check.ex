defmodule Mix.Tasks.Lcars.Contracts.Check do
  use Boundary, classify_to: Fleet.Application

  @shortdoc "Runs source and declaration contract checks"

  @moduledoc """
  Compiles the project, runs the checks listed in `run_checks/0`, and exits with
  status 1 if any verdict fails. Run from the runtime directory:

      mix lcars.contracts.check
      mix lcars.contracts.check --quiet

  The detailed report is YAML-like text with unescaped values, followed by a summary.
  `--quiet` suppresses the detailed report, but still prints the summary.
  Individual checks live in `Check.*`; their source/AST patterns do not prove runtime behavior.
  """

  alias Mix.Tasks.Lcars.Contracts.Check.Artifact
  alias Mix.Tasks.Lcars.Contracts.Check.Boot
  alias Mix.Tasks.Lcars.Contracts.Check.Catalogue
  alias Mix.Tasks.Lcars.Contracts.Check.Events
  alias Mix.Tasks.Lcars.Contracts.Check.Runtime
  alias Mix.Tasks.Lcars.Contracts.Check.SingleSource
  alias Mix.Tasks.Lcars.Contracts.Check.Tests
  alias Mix.Tasks.Lcars.Contracts.Check.Tools
  alias Mix.Tasks.Lcars.Contracts.Check.Types

  use Mix.Task

  @recursive false

  @impl Mix.Task
  def run(args) do
    quiet? = "--quiet" in args

    # Keep Logger output separate from the report.
    Fleet.ReleaseDoor.claim_stdout!()

    Mix.Task.run("compile")

    {overall, checks} = run_checks()

    unless quiet?, do: IO.puts(render_yaml(overall, checks))

    fails = Enum.count(checks, &(&1.status == :fail))

    Mix.shell().info(
      "contracts.check: #{overall} — #{fails} fail, " <>
        "#{Enum.count(checks, &(&1.status == :pass))} pass"
    )

    if overall == :fail, do: exit({:shutdown, 1})
  end

  @doc """
  Returns aggregate verdicts using the current directory as the runtime root.
  Does not render the report or choose an exit code. Checks can raise, log or start
  dependencies; an exception interrupts the remaining checks.
  """
  @spec run_checks() :: {:pass | :fail, [map()]}
  def run_checks do
    root = project_root()

    checks =
      [
        Events.check_event_consumers_canon(root),
        Events.check_pipeline_envelope_normalized(root),
        Events.check_events_handlers_exist(root),
        Runtime.check_gates_no_runtime_seam(root),
        Events.check_visual_types_derived(root),
        Events.check_escalation_kinds_closed(root),
        Events.check_findings_severities_aligned(root),
        Events.check_pulled_states_declared(root),
        Types.check_public_functions_spec(root),
        Runtime.check_capprofile_lifetime_scope_path(root),
        Runtime.check_capprofile_modop_incompatible_path(root),
        Runtime.check_launch_backend_containment(root),
        Runtime.check_mcp_required_real_backend(root),
        Runtime.check_spawn_has_brief(root),
        Catalogue.check_skills_declared_present(root),
        Events.check_events_registry_keys_aligned(root),
        Runtime.check_no_cowboy_bypass(root),
        # ── Remediation rails ──
        Runtime.check_result_deadline_cancelled(root),
        Runtime.check_spawn_gates_wired(root),
        Runtime.check_gatekeeper_not_a_step(root),
        Runtime.check_verdict_envelope_unwrapped(root),
        Runtime.check_no_root_runtime_guard(root),
        # ── Topology lock ──
        Boot.check_boot_order_f8(root),
        Boot.check_catalogue_before_freeze(root),
        Boot.check_event_registry_loaded_before_children(root),
        # ── Authority locks (Z7 — one fact = one source, cross-language) ──
        Catalogue.check_roles_provisioning_locked(root),
        Catalogue.check_roles_role_index_unique(root),
        Catalogue.check_sp_adresser_un_agent(root),
        Artifact.check_sourcers_set_strict(root),
        Catalogue.check_face_roots_provisioned(root),
        SingleSource.check_toolchain_branch_single_source(root),
        SingleSource.check_catalogue_roots_single_source(root),
        SingleSource.check_private_dir_single_source(root),
        SingleSource.check_system_account_single_source(root),
        SingleSource.check_platform_root_single_source(root),
        SingleSource.check_runtime_root_single_source(root),
        SingleSource.check_face_roots_single_source(root),
        SingleSource.check_ops_repo_single_source(root),
        SingleSource.check_config_single_default(root),
        SingleSource.check_forge_shape_contained(root),
        Tools.check_tool_descriptions_no_permuted_names(root),
        Tools.check_tool_grants_resolve(root),
        Tools.check_catalogue_enumerates_no_tools(root),
        Runtime.check_eval_doors_claim_stdout(root),
        Artifact.check_gitea_template_expansion(root),
        Artifact.check_site_build_inputs(root),
        Artifact.check_bats_descriptions_inert(root),
        Runtime.check_awaits_arch_clears_in_flight(root),
        Artifact.check_sanctuary_contained(root),
        Artifact.check_no_legacy_config_namespace(root),
        Tools.check_mcp_wire_inputschema(root),
        Tools.check_vitrine_single_line(root),
        Tools.check_mcp_tools_gated(root),
        Tools.check_mcp_tool_effects(root),
        Tools.check_cap_profile_project_keys(root),
        Tools.check_modop_tools_granted(root),
        Artifact.check_proven_image_regime(root),
        Runtime.check_verifier_covers_rail(root),
        Runtime.check_workflow_loader_arity(root),
        Tools.check_capabilities_exercisable(root),
        Catalogue.check_catalogue_paths_locked(root),
        Runtime.check_eval_doors_start_transport(root),
        Runtime.check_eval_doors_resolve(root),
        Runtime.check_bare_alias_resolves(root),
        Tools.check_mcp_seam_surface(root),
        Tools.check_forge_fields_read(root),
        Tools.check_forge_mutations_exposed(root),
        Runtime.check_declaration_max_fan_ceiling(root),
        Tests.check_test_corpora_on_record(root),
        Tests.check_doctest_declarations_have_examples(root),
        Tests.check_test_dirs_mirror_source(root),
        Tests.check_witness_naming(root),
        Tests.check_negations_bite(root),
        Tests.check_refute_copies_agree(root),
        Types.check_public_functions_documented(root)
        # Bounded rework belongs to StepRunConsumer's forge rail (`max_rework_rounds`).
      ]

    overall = if Enum.any?(checks, &(&1.status == :fail)), do: :fail, else: :pass

    {overall, checks}
  end

  defp project_root, do: File.cwd!()

  defp render_yaml(overall, checks) do
    header = "status: #{overall}\nchecks:"

    body =
      Enum.map_join(checks, "\n", fn c ->
        ev =
          case c.evidence do
            [] -> ""
            list -> "\n    evidence:\n" <> Enum.map_join(list, "\n", &"      - #{&1}")
          end

        "  - id: #{c.id}\n" <>
          "    remediation: #{c.remediation}\n" <>
          "    status: #{c.status}\n" <>
          "    note: #{c.note}" <> ev
      end)

    header <> "\n" <> body
  end
end
