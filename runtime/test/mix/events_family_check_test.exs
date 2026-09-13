defmodule Mix.Tasks.Lcars.Contracts.EventsFamilyCheckTest do
  @moduledoc """
  Synthetic-tree tests for event handlers, registry keys, consumer syntax,
  envelope normalization, severity enums, escalation kinds and visual types.

  Fixtures exercise source/YAML comparisons, not event delivery or handler execution.
  Visual-type tests isolate count mismatch, literal duplication and missing derivation
  references so one failed condition does not mask another.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Lcars.Contracts.Check.Events

  defp arbre(fichiers) do
    root = Fleet.TestEnv.tmp_path("murs_events")
    on_exit(fn -> File.rm_rf!(root) end)

    for {rel, contenu} <- fichiers do
      chemin = Path.join(root, rel)
      File.mkdir_p!(Path.dirname(chemin))
      File.write!(chemin, contenu)
    end

    root
  end

  defp yaml(evenements), do: {"priv/event_router/events.yaml", "events:\n" <> evenements}

  describe "events.handlers.exist — une route vers un module fantome" do
    test "un handler qui n'existe pas est NOMME" do
      root =
        arbre([
          yaml(
            "  \"pod.completed\":\n    - Fleet.Pilot.StepRunCompleter\n" <>
              "  \"pod.dead\":\n    - Fleet.NExistePas.Handler\n"
          )
        ])

      assert %{status: :fail, evidence: [ev]} = Events.check_events_handlers_exist(root)
      assert ev =~ "Fleet.NExistePas.Handler"
      assert ev =~ "missing"
    end

    test "des handlers qui existent tous → vert" do
      root = arbre([yaml("  \"pod.completed\":\n    - Fleet.EventRouter.Bus\n")])

      assert %{status: :pass, evidence: []} = Events.check_events_handlers_exist(root)
    end

    test "⚠ UN REGISTRE ABSENT NE VAUT PAS « aucun handler fantome »" do
      assert %{status: :fail, evidence: [ev]} = Events.check_events_handlers_exist(arbre([]))
      assert ev =~ "absent or invalid"
      assert ev =~ "hollow-green guard"
    end

    test "un registre ILLISIBLE tombe du meme cote qu'un registre absent" do
      root = arbre([{"priv/event_router/events.yaml", "ceci: n'est pas: du yaml: valide: [\n"}])

      assert %{status: :fail, evidence: [ev]} = Events.check_events_handlers_exist(root)
      assert ev =~ "absent or invalid"
    end
  end

  describe "events.registry.keys_aligned — un type consomme hors registre" do
    @consommateur """
    defmodule Fleet.Truc do
      def handle_info(%Fleet.Event{type: :"pod.completed"}, s), do: {:noreply, s}
      def handle_info(%Fleet.Event{type: :"pod.jamais_declare"}, s), do: {:noreply, s}
    end
    """

    test "un `handle_info %Fleet.Event{type:}` absent du registre est NOMME" do
      root =
        arbre([
          yaml("  \"pod.completed\": []\n"),
          {"lib/fleet/truc.ex", @consommateur}
        ])

      assert %{status: :fail, evidence: [ev]} = Events.check_events_registry_keys_aligned(root)
      assert ev =~ "pod.jamais_declare"
    end

    test "tous les types consommes declares → vert" do
      root =
        arbre([
          yaml(~s|  "pod.completed": []\n  "pod.jamais_declare": []\n|),
          {"lib/fleet/truc.ex", @consommateur}
        ])

      assert %{status: :pass, evidence: []} = Events.check_events_registry_keys_aligned(root)
    end

    test "⚠ LES DEUX COTES SONT UNE POPULATION — une source vide rend le mur muet" do
      root = arbre([yaml("  \"pod.completed\": []\n")])

      assert %{status: :fail, evidence: [ev]} = Events.check_events_registry_keys_aligned(root)
      assert ev =~ "INSTRUMENT BROKEN"
      assert ev =~ "source under lib/"
    end

    test "un registre vide se denonce aussi" do
      root = arbre([yaml(""), {"lib/fleet/truc.ex", @consommateur}])

      assert %{status: :fail, evidence: [ev]} = Events.check_events_registry_keys_aligned(root)
      assert ev =~ "INSTRUMENT BROKEN"
      assert ev =~ "key in events.yaml"
    end
  end

  describe "event.consumers.canon — le tuple `event_type` d'avant" do
    test "un consommateur sur la forme d'avant est NOMME, ou qu'il soit sous lib/" do
      root =
        arbre([
          {"lib/fleet/quelque/part/loin.ex",
           "defmodule L do\n  def go(%{\"event_type\" => t}), do: t\nend\n"}
        ])

      assert %{status: :fail, evidence: ev} = Events.check_event_consumers_canon(root)
      assert Enum.any?(ev, &(&1 =~ "loin.ex"))
    end

    test "le canon `%Fleet.Event{}` passe" do
      root =
        arbre([
          {"lib/fleet/ok.ex", "defmodule O do\n  def go(%Fleet.Event{type: t}), do: t\nend\n"}
        ])

      assert %{status: :pass, evidence: []} = Events.check_event_consumers_canon(root)
    end
  end

  describe "pipeline.envelope.normalized — la clause qui deplie l'enveloppe" do
    @loader_ok """
    defmodule Fleet.Workflow.Loader do
      defp normalize(%{"spec" => %{"steps" => s}} = y), do: Map.put(y, "steps", s)
      def load(yaml), do: normalize(yaml)
    end
    """

    test "la clause presente ET appelee → vert" do
      assert %{status: :pass, evidence: []} =
               Events.check_pipeline_envelope_normalized(
                 arbre([{"lib/fleet/workflow/loader.ex", @loader_ok}])
               )
    end

    test "la clause presente mais JAMAIS appelee est nommee" do
      sans_appel =
        String.replace(@loader_ok, "def load(yaml), do: normalize(yaml)", "def load(y), do: y")

      assert %{status: :fail, evidence: [ev]} =
               Events.check_pipeline_envelope_normalized(
                 arbre([{"lib/fleet/workflow/loader.ex", sans_appel}])
               )

      assert ev =~ "never called"
    end

    test "⚠ UNE CLAUSE COMMENTEE NE COMPTE PAS — le mur lit le CODE, pas la prose" do
      commentee =
        """
        defmodule Fleet.Workflow.Loader do
          # defp normalize(%{"spec" => %{"steps" => s}}), do: s
          # ancien depliage, retire — voir normalize(yaml) plus bas
          def load(y), do: y
        end
        """

      assert %{status: :fail, evidence: [ev]} =
               Events.check_pipeline_envelope_normalized(
                 arbre([{"lib/fleet/workflow/loader.ex", commentee}])
               )

      assert ev =~ "clause (envelope unwrap) missing"
    end
  end

  describe "findings.severities_aligned — un vocabulaire ecrit d'un seul cote" do
    defp findings(code_sev, enum_sev, enum_max) do
      [
        {"lib/fleet/findings_wire.ex",
         "defmodule Fleet.FindingsWire do\n  def severities, do: #{inspect(code_sev)}\nend\n"},
        {"priv/workflow/schema/findings.json",
         Jason.encode!(%{
           "properties" => %{
             "findings" => %{
               "items" => %{"properties" => %{"severity" => %{"enum" => enum_sev}}}
             },
             "severity_max" => %{"enum" => enum_max}
           }
         })}
      ]
    end

    test "les trois vocabulaires d'accord → vert" do
      root = arbre(findings(~w(low high), ~w(low high), ~w(low high none)))
      assert %{status: :pass, evidence: []} = Events.check_findings_severities_aligned(root)
    end

    test "une severite absente de l'enum par-finding est nommee" do
      root = arbre(findings(~w(low high critical), ~w(low high), ~w(low high critical none)))

      assert %{status: :fail, evidence: ev} = Events.check_findings_severities_aligned(root)
      assert Enum.any?(ev, &(&1 =~ "absente de l'enum severity" and &1 =~ "critical"))
    end

    test "⚠ LE SECOND ENUM EST LU AUSSI — c'est le seul qu'une porte compare" do
      # Check the aggregate severity enum independently of the per-finding enum.
      root = arbre(findings(~w(low high), ~w(low high), ~w(low none)))

      assert %{status: :fail, evidence: ev} = Events.check_findings_severities_aligned(root)
      assert Enum.any?(ev, &(&1 =~ "severity_max" and &1 =~ "high"))
    end

    test "un schema illisible → INSTRUMENT BROKEN, pas « rien a comparer »" do
      root =
        arbre([
          {"lib/fleet/findings_wire.ex",
           "defmodule Fleet.FindingsWire do\n  def severities, do: [\"low\"]\nend\n"}
        ])

      assert %{status: :fail, evidence: [ev]} = Events.check_findings_severities_aligned(root)
      assert ev =~ "INSTRUMENT BROKEN"
    end
  end

  describe "incident.kinds_closed — la table des kinds, fermee dans les DEUX sens" do
    defp escalade(clauses),
      do:
        {"lib/fleet/pilot/incident_registry/escalation.ex",
         "defmodule Fleet.Pilot.IncidentRegistry.Escalation do\n" <>
           Enum.map_join(clauses, "", fn k ->
             "  defp kind_describe(#{inspect(k)}), do: \"x\"\n"
           end) <> "end\n"}

    test "un kind EMIS sans clause est nomme — sinon l'escalade CRASHE au lieu d'ouvrir l'issue" do
      root =
        arbre([
          escalade([:recurrence]),
          {"lib/fleet/appelant.ex",
           "defmodule A do\n  def go, do: record_or_escalate(1, 2, 3, escalate_kind: :disque_plein)\nend\n"},
          {"priv/event_router/events.yaml", "events: {}\n"}
        ])

      assert %{status: :fail, evidence: ev} = Events.check_escalation_kinds_closed(root)
      assert Enum.any?(ev, &(&1 =~ "emis SANS clause" and &1 =~ "disque_plein"))
    end

    test "une clause MORTE est nommee aussi — elle annonce une remontee que personne ne declenche" do
      root =
        arbre([
          escalade([:recurrence, :jamais_produit]),
          {"lib/fleet/appelant.ex",
           "defmodule A do\n  def go, do: record_or_escalate(1, 2, 3, escalate_kind: :recurrence)\nend\n"},
          {"priv/event_router/events.yaml", "events: {}\n"}
        ])

      assert %{status: :fail, evidence: ev} = Events.check_escalation_kinds_closed(root)
      assert Enum.any?(ev, &(&1 =~ "clause MORTE" and &1 =~ "jamais_produit"))
    end

    test "⚠ UN `escalate_kind` EN COMMENTAIRE DU YAML NE GARDE PAS UNE CLAUSE VIVANTE" do
      root =
        arbre([
          escalade([:recurrence, :zzz_mort]),
          {"lib/fleet/appelant.ex",
           "defmodule A do\n  def go, do: record_or_escalate(1, 2, 3, escalate_kind: :recurrence)\nend\n"},
          {"priv/event_router/events.yaml",
           "events:\n  # historique : on avait un jour escalate_kind: zzz_mort\n  \"x\": []\n"}
        ])

      assert %{status: :fail, evidence: ev} = Events.check_escalation_kinds_closed(root)
      assert Enum.any?(ev, &(&1 =~ "clause MORTE" and &1 =~ "zzz_mort"))
    end

    test "les deux ensembles egaux → vert, et le YAML est bien une source de production" do
      root =
        arbre([
          escalade([:recurrence, :route_immediate]),
          {"lib/fleet/appelant.ex",
           "defmodule A do\n  def go, do: record_or_escalate(1, 2, 3, escalate_kind: :recurrence)\nend\n"},
          {"priv/event_router/events.yaml",
           "events:\n  \"pod.dead\":\n    escalate_kind: route_immediate\n"}
        ])

      assert %{status: :pass, evidence: []} = Events.check_escalation_kinds_closed(root)
    end
  end

  describe "labels.visual_types_derived — un type produit et jamais seme nait gris" do
    defp labels(corps_visual, n_dest, n_clauses) do
      {"lib/fleet/labels.ex",
       "defmodule Fleet.Labels do\n" <>
         "  @destinations #{inspect(Enum.map(1..n_dest, &"d#{&1}"))}\n" <>
         Enum.map_join(1..n_clauses, "", fn i ->
           "  def type_for_destination(\"d#{i}\"), do: \"type:d#{i}\"\n"
         end) <>
         "  def visual_types, do: #{corps_visual}\n" <>
         "end\n"}
    end

    test "la derivation presente et les comptes egaux → vert" do
      root = arbre([labels("Enum.map(@destinations, &type_for_destination/1)", 2, 2)])
      assert %{status: :pass, evidence: []} = Events.check_visual_types_derived(root)
    end

    test "une clause de plus que de destinations est nommee" do
      root = arbre([labels("Enum.map(@destinations, &type_for_destination/1)", 2, 3)])
      assert %{status: :fail} = Events.check_visual_types_derived(root)
    end

    test "⚠ LA RECOPIE LITTERALE EST REFUSEE — c'est elle qui a diverge seize jours" do
      root = arbre([labels(~s(["type:d1", "type:d2"]), 2, 2)])

      assert %{status: :fail, evidence: ev} = Events.check_visual_types_derived(root)
      assert ev != []
    end

    test "⚠ LA DERIVATION EST UNE MOITIE A PART — sans litteral et sans lecture, c'est ROUGE aussi" do
      # Counts agree and no literals remain: only the missing derivation references must fail.
      root = arbre([labels("une_autre_source()", 2, 2)])

      assert %{status: :fail, evidence: ev} = Events.check_visual_types_derived(root)
      assert Enum.any?(ev, &(&1 =~ "ne lit pas @destinations"))
    end

    test "`@destinations` absent → INSTRUMENT BROKEN" do
      root =
        arbre([
          {"lib/fleet/labels.ex",
           "defmodule Fleet.Labels do\n" <>
             ~s|  def type_for_destination("d1"), do: "type:d1"\n| <>
             "  def visual_types, do: Enum.map(@destinations, &type_for_destination/1)\n" <>
             "end\n"}
        ])

      assert %{status: :fail, evidence: [ev]} = Events.check_visual_types_derived(root)
      assert ev =~ "INSTRUMENT BROKEN"
      assert ev =~ "@destinations"
    end
  end
end
