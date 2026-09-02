defmodule Mix.Tasks.Lcars.Contracts.Check do
  # Z4 — Mix task classified into the boundary of its subject (Fleet.Application).
  use Boundary, classify_to: Fleet.Application

  @shortdoc "Verifies inter-module contracts at load (refuses the build if a contract is reopened)"

  @moduledoc """
  Runtime Contract Checker — validates inter-module contracts BEFORE
  execution, and turns each gap into an explicit refusal (exit≠0)
  rather than a silent runtime timeout/bug.

  Each check guards a class of drift already encountered: RED as long as the
  fix is not landed, GREEN once it is. Wired in as a permanent guardrail
  (`contracts.check` exit 0 at boot/CI fail-loud, and `mix release` refuses to
  build if a check is red), it promotes each invariant from a documentary
  closure to a mechanical closure: an agent who re-derives breaks the build.

  ## Usage

      mix lcars.contracts.check          # YAML report + exit 0/1
      mix lcars.contracts.check --quiet  # exit code only

  ## Output

  YAML `status + checks[] + evidence (file:line)`. `status: fail` if at
  least one check is `fail`. Every check is IMPLEMENTED and grounded in the real
  code (grep/introspection) — there is no "pending/declared-only" tier: a contract
  either has an executable check or it is not listed.

  ## Ou sont les murs

  Pas ici. Ce module n'en mesure aucun : il enchaine les familles, agrege leurs verdicts, rend le
  YAML et choisit le code de sortie. Les murs vivent dans `Check.<Famille>`, et `run_checks/0` les
  nomme un par un — la liste d'appels EST l'autorite sur ce que le gate joue, et se lit comme une
  table de ce que le projet garde :

      Support       l'outillage partage — combinateurs, lecteurs de code, parcours de corpus
      Runtime       les rails et les coutures que ni un type ni un test ne traversent
      Tools         la surface d'outils : catalogue, MCP, capacites, client forge
      SingleSource  Z7 — un fait, une source, a travers les langages
      Catalogue     le catalogue de roles : son lecteur, et les murs qui l'interrogent
      Events        la voie des evenements et les vocabulaires fermes
      Artifact      ce que l'artefact contient et ce que ses arbres voisins promettent
      Tests         le corpus de temoins lui-meme : joue, retrouvable, mordant
      Types         les jumeaux `@spec` et `@doc` sur les fonctions publiques
      Boot          le verrou de topologie : l'ORDRE du demarrage

  ⚠ CE FICHIER FAISAIT 7134 LIGNES. Le decoupage du 2026-09-02 n'a rien change au comportement — 69
  murs avant, 69 apres, verifies par la tache et non de memoire — mais il a change ce qu'un lecteur
  doit tenir en tete pour en ouvrir un seul.
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

  # ⚠ NI `alias Support` NI `import Support` ICI, ET C'EST LE SIGNE QUE LA COUPE EST FINIE : cette
  # tache ne mesure plus rien. Elle enchaine les familles, agrege leurs verdicts, rend le YAML et
  # choisit le code de sortie. Le jour ou un `Support.` reapparait dans ce fichier, c'est qu'un mur
  # y a ete ecrit au lieu d'aller dans sa famille.

  use Mix.Task

  @recursive false

  # Each check: %{id, remediation, status: :pass|:fail, evidence: [..], note}
  # (The `@pending_checks` machinery — a list that was ALWAYS empty, a counter that always
  # printed "0 pending" — was inert ceremony, removed acte4 A-16. Reintroduce a pending tier
  # only the day a real declared-but-not-yet-executable check exists.)

  @impl Mix.Task
  def run(args) do
    quiet? = "--quiet" in args
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
  Runs the compiled-source checks without printing or exiting.
  """
  @spec run_checks() :: {:pass | :fail, [map()]}
  def run_checks do
    root = project_root()

    checks =
      [
        Events.check_event_consumers_canon(root),
        Events.check_pipeline_v25_normalized(root),
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
        Tools.check_mcp_tools_gated(root),
        Tools.check_mcp_tool_effects(root),
        Tools.check_cap_profile_project_keys(root),
        Tools.check_modop_tools_granted(root),
        Artifact.check_proven_image_regime(root),
        Runtime.check_verifier_covers_rail(root),
        Tools.check_capabilities_exercisable(root),
        Catalogue.check_catalogue_paths_locked(root),
        Runtime.check_eval_doors_start_transport(root),
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
        # NB no `pipeline.bounded_retry_system_side` rail here: bounded rework lives on the
        # forge rail (`max_rework_rounds`, StepRunConsumer), not an in-memory retry loop —
        # nothing separate to contract.
      ]

    overall = if Enum.any?(checks, &(&1.status == :fail)), do: :fail, else: :pass

    {overall, checks}
  end

  defp project_root, do: File.cwd!()

  defp render_yaml(overall, checks) do
    header = "status: #{overall}\nchecks:"

    body =
      Enum.map_join(checks, "\n", fn c ->
        # FIELD access (c.evidence/c.note like c.id/c.status): every producer sets the
        # 5 keys — a defaulted Map.get would mask a guaranteed shape (dead default).
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
