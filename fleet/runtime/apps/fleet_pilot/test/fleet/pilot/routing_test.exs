defmodule Fleet.Pilot.RoutingTest do
  use ExUnit.Case, async: true

  alias Fleet.Pilot.Routing

  describe "load_routes/1" do
    @tag :tmp_dir
    test "charge les routes depuis un fichier YAML valide", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "routing.yaml")

      File.write!(path, """
      routes:
        - on: [gitea.opened]
          when:
            type: poc
          pipeline: poc-cycle
        - on: [gitea.labeled]
          when:
            state: dispatched
          pipeline: dispatch-cycle
      """)

      assert [
               %{
                 "on" => ["gitea.opened"],
                 "when" => %{"type" => "poc"},
                 "pipeline" => "poc-cycle"
               },
               %{
                 "on" => ["gitea.labeled"],
                 "when" => %{"state" => "dispatched"},
                 "pipeline" => "dispatch-cycle"
               }
             ] = Routing.load_routes(path)
    end

    @tag :tmp_dir
    test "retourne [] si la clé `routes` est absente", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "routing.yaml")
      File.write!(path, "other_key: foo\n")

      assert [] = Routing.load_routes(path)
    end

    @tag :tmp_dir
    test "retourne [] si le YAML est invalide", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "routing.yaml")
      File.write!(path, "::: not valid yaml :::\n  - broken\n")

      assert [] = Routing.load_routes(path)
    end

    @tag :tmp_dir
    test "retourne [] si le fichier est absent", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "absent.yaml")

      assert [] = Routing.load_routes(path)
    end

    @tag :tmp_dir
    test "retourne [] si `routes` n'est pas une liste", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "routing.yaml")
      File.write!(path, "routes: not_a_list\n")

      assert [] = Routing.load_routes(path)
    end
  end

  describe "match_event/3 — event_type" do
    test "match `on:` en liste" do
      routes = [%{"on" => ["gitea.opened"], "pipeline" => "p1"}]

      assert {:match, "p1"} = Routing.match_event("gitea.opened", %{}, routes)
    end

    test "match `on:` en binary (single string)" do
      routes = [%{"on" => "gitea.opened", "pipeline" => "p1"}]

      assert {:match, "p1"} = Routing.match_event("gitea.opened", %{}, routes)
    end

    test "no_match si event_type pas dans `on:`" do
      routes = [%{"on" => ["gitea.opened"], "pipeline" => "p1"}]

      assert :no_match = Routing.match_event("gitea.closed", %{}, routes)
    end

    test "no_match si routes vides" do
      assert :no_match = Routing.match_event("gitea.opened", %{}, [])
    end

    test "no_match si `on:` absent" do
      routes = [%{"pipeline" => "p1"}]

      assert :no_match = Routing.match_event("gitea.opened", %{}, routes)
    end
  end

  describe "match_event/3 — when filters" do
    test "match `when: type` depuis label issue" do
      routes = [
        %{
          "on" => ["gitea.opened"],
          "when" => %{"type" => "poc"},
          "pipeline" => "poc-cycle"
        }
      ]

      payload = %{"issue" => %{"labels" => [%{"name" => "type:poc"}]}}

      assert {:match, "poc-cycle"} = Routing.match_event("gitea.opened", payload, routes)
    end

    test "no_match si `when: type` ne correspond pas au label" do
      routes = [
        %{
          "on" => ["gitea.opened"],
          "when" => %{"type" => "poc"},
          "pipeline" => "poc-cycle"
        }
      ]

      payload = %{"issue" => %{"labels" => [%{"name" => "type:sysadmin"}]}}

      assert :no_match = Routing.match_event("gitea.opened", payload, routes)
    end

    test "match `when: state` depuis label issue" do
      routes = [
        %{
          "on" => ["gitea.labeled"],
          "when" => %{"state" => "dispatched"},
          "pipeline" => "x"
        }
      ]

      payload = %{"issue" => %{"labels" => [%{"name" => "state:dispatched"}]}}

      assert {:match, "x"} = Routing.match_event("gitea.labeled", payload, routes)
    end

    test "match `when: assignee` depuis premier assignee" do
      routes = [
        %{
          "on" => ["gitea.assigned"],
          "when" => %{"assignee" => "engineer"},
          "pipeline" => "p"
        }
      ]

      payload = %{"issue" => %{"assignees" => [%{"login" => "engineer"}]}}

      assert {:match, "p"} = Routing.match_event("gitea.assigned", payload, routes)
    end

    test "wildcard : `when` absent = ne contraint pas" do
      routes = [%{"on" => ["gitea.opened"], "pipeline" => "always"}]

      assert {:match, "always"} =
               Routing.match_event("gitea.opened", %{"issue" => %{}}, routes)
    end

    test "tous les filtres `when` doivent matcher (AND)" do
      routes = [
        %{
          "on" => ["gitea.opened"],
          "when" => %{"type" => "poc", "assignee" => "engineer"},
          "pipeline" => "p"
        }
      ]

      payload_ok = %{
        "issue" => %{
          "labels" => [%{"name" => "type:poc"}],
          "assignees" => [%{"login" => "engineer"}]
        }
      }

      payload_partial = %{
        "issue" => %{
          "labels" => [%{"name" => "type:poc"}],
          "assignees" => [%{"login" => "qualifier"}]
        }
      }

      assert {:match, "p"} = Routing.match_event("gitea.opened", payload_ok, routes)
      assert :no_match = Routing.match_event("gitea.opened", payload_partial, routes)
    end

    test "clé `when` inconnue : la route ne match pas (fail-closed)" do
      routes = [
        %{
          "on" => ["gitea.opened"],
          "when" => %{"unknown_key" => "x"},
          "pipeline" => "p"
        }
      ]

      assert :no_match = Routing.match_event("gitea.opened", %{}, routes)
    end
  end

  describe "match_event/3 — priorité" do
    test "1ère route qui match gagne (ordre = priorité)" do
      routes = [
        %{"on" => ["gitea.opened"], "when" => %{"type" => "poc"}, "pipeline" => "first"},
        %{"on" => ["gitea.opened"], "when" => %{"type" => "poc"}, "pipeline" => "second"}
      ]

      payload = %{"issue" => %{"labels" => [%{"name" => "type:poc"}]}}

      assert {:match, "first"} = Routing.match_event("gitea.opened", payload, routes)
    end

    test "skip route sans pipeline valide, essaie la suivante" do
      routes = [
        %{"on" => ["gitea.opened"], "pipeline" => ""},
        %{"on" => ["gitea.opened"], "pipeline" => nil},
        %{"on" => ["gitea.opened"], "pipeline" => "good"}
      ]

      assert {:match, "good"} = Routing.match_event("gitea.opened", %{}, routes)
    end
  end

  describe "match_issue/2 — by when only (poller catch-up)" do
    test "match `when: type` sur issue, ignore `on:`" do
      routes = [
        %{
          "on" => ["gitea.opened"],
          "when" => %{"type" => "poc"},
          "pipeline" => "poc-cycle"
        }
      ]

      payload = %{"issue" => %{"labels" => [%{"name" => "type:poc"}]}}

      assert {:match, "poc-cycle"} = Routing.match_issue(payload, routes)
    end

    test "no_match si when ne correspond pas" do
      routes = [
        %{
          "on" => ["gitea.opened"],
          "when" => %{"type" => "poc"},
          "pipeline" => "poc-cycle"
        }
      ]

      payload = %{"issue" => %{"labels" => [%{"name" => "type:sysadmin"}]}}

      assert :no_match = Routing.match_issue(payload, routes)
    end

    test "1ère route qui match gagne (priorité)" do
      routes = [
        %{"on" => ["gitea.opened"], "when" => %{"type" => "poc"}, "pipeline" => "first"},
        %{"on" => ["gitea.opened"], "when" => %{"type" => "poc"}, "pipeline" => "second"}
      ]

      payload = %{"issue" => %{"labels" => [%{"name" => "type:poc"}]}}

      assert {:match, "first"} = Routing.match_issue(payload, routes)
    end

    test "wildcard `when` absent = match toujours" do
      routes = [%{"on" => ["gitea.opened"], "pipeline" => "always"}]

      assert {:match, "always"} = Routing.match_issue(%{"issue" => %{}}, routes)
    end

    test "ignore le filtre `on:` (différence clé vs match_event)" do
      # Route a `on: [gitea.opened]` mais match_issue doit ignorer →
      # poller dispatchable sans event d'origine.
      routes = [
        %{
          "on" => ["gitea.opened"],
          "when" => %{"type" => "poc"},
          "pipeline" => "p"
        }
      ]

      payload = %{"issue" => %{"labels" => [%{"name" => "type:poc"}]}}

      # Aucun event_type fourni → match_event aurait besoin du type,
      # match_issue n'en a pas besoin.
      assert {:match, "p"} = Routing.match_issue(payload, routes)
    end
  end

  describe "extract_fields/1" do
    test "extrait type/state/assignee depuis payload complet" do
      payload = %{
        "issue" => %{
          "labels" => [
            %{"name" => "type:poc"},
            %{"name" => "state:dispatched"},
            %{"name" => "priority:high"}
          ],
          "assignees" => [%{"login" => "engineer"}, %{"login" => "qualifier"}]
        }
      }

      assert %{type: "poc", state: "dispatched", assignee: "engineer"} =
               Routing.extract_fields(payload)
    end

    test "retourne nil pour champs absents" do
      assert %{type: nil, state: nil, assignee: nil} = Routing.extract_fields(%{})
    end

    test "retourne nil si issue absent" do
      assert %{type: nil, state: nil, assignee: nil} =
               Routing.extract_fields(%{"other" => "x"})
    end

    test "retourne nil si labels vide" do
      payload = %{"issue" => %{"labels" => []}}

      assert %{type: nil, state: nil, assignee: nil} = Routing.extract_fields(payload)
    end

    test "ignore les labels mal formés (pas de name binaire)" do
      payload = %{
        "issue" => %{
          "labels" => [
            %{"description" => "no name field"},
            "raw_string_label",
            %{"name" => "type:poc"}
          ]
        }
      }

      assert %{type: "poc"} = Routing.extract_fields(payload)
    end

    test "1er label matchant gagne pour un prefix donné" do
      payload = %{
        "issue" => %{
          "labels" => [
            %{"name" => "type:first"},
            %{"name" => "type:second"}
          ]
        }
      }

      assert %{type: "first"} = Routing.extract_fields(payload)
    end
  end
end
