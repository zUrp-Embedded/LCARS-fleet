defmodule Fleet.ClaudeBridge.SPInjectionTest do
  use ExUnit.Case, async: true

  alias Fleet.ClaudeBridge.SPInjection

  doctest Fleet.ClaudeBridge.SPInjection

  defp profile(scope_overrides \\ %{}) do
    scope =
      Map.merge(
        %{
          "allowedTools" => ["Read", "Glob"],
          "disallowedTools" => ["web_search"]
        },
        scope_overrides
      )

    %Fleet.CapProfile{
      api_version: "lcars/v2.5",
      kind: "CapabilityProfile",
      metadata: %{"name" => "engineer"},
      spec: %{"scope" => scope}
    }
  end

  describe "build_flags/2 — N2 system-prompt-file obligatoire" do
    test "raise si :sp_path manquant" do
      assert_raise KeyError, fn ->
        SPInjection.build_flags(profile(), brief_path: "/tmp/brief.md")
      end
    end

    test "inclut --output-format stream-json + --verbose" do
      flags = SPInjection.build_flags(profile(), sp_path: "/tmp/sp.md")
      assert ["--output-format", "stream-json", "--verbose" | _] = flags
    end

    test "inclut --system-prompt-file <sp_path>" do
      flags = SPInjection.build_flags(profile(), sp_path: "/tmp/sp.md")
      assert "--system-prompt-file" in flags
      assert "/tmp/sp.md" in flags
    end
  end

  describe "build_flags/2 — N2bis brief optionnel" do
    test "sans :brief_path → pas de --append-system-prompt-file" do
      flags = SPInjection.build_flags(profile(), sp_path: "/tmp/sp.md")
      refute "--append-system-prompt-file" in flags
    end

    test "avec :brief_path → injection --append-system-prompt-file <brief>" do
      flags =
        SPInjection.build_flags(profile(),
          sp_path: "/tmp/sp.md",
          brief_path: "/tmp/brief.md"
        )

      assert "--append-system-prompt-file" in flags
      assert "/tmp/brief.md" in flags
    end
  end

  describe "build_flags/2 — listes outils CSV" do
    test "allowed/disallowed jointes en CSV" do
      flags = SPInjection.build_flags(profile(), sp_path: "/tmp/sp.md")
      assert "Read,Glob" in flags
      assert "web_search" in flags
    end

    test "scope.allowedTools manquant → CSV vide" do
      cp = %Fleet.CapProfile{
        api_version: "lcars/v2.5",
        kind: "CapabilityProfile",
        metadata: %{"name" => "x"},
        spec: %{"scope" => %{"disallowedTools" => ["x"]}}
      }

      flags = SPInjection.build_flags(cp, sp_path: "/tmp/sp.md")
      assert "--allowedTools" in flags
      assert "" in flags
    end

    test "spec.scope manquant → CSV vides côté allowed et disallowed" do
      cp = %Fleet.CapProfile{
        api_version: "lcars/v2.5",
        kind: "CapabilityProfile",
        metadata: %{"name" => "x"},
        spec: %{}
      }

      flags = SPInjection.build_flags(cp, sp_path: "/tmp/sp.md")
      assert "--allowedTools" in flags
      assert "--disallowedTools" in flags
    end
  end

  describe "build_flags/2 — budget" do
    test "default \"1.0\" si :budget_usd absent" do
      flags = SPInjection.build_flags(profile(), sp_path: "/tmp/sp.md")
      assert "--max-budget-usd" in flags
      assert "1.0" in flags
    end

    test "accept number → cast string" do
      flags = SPInjection.build_flags(profile(), sp_path: "/tmp/sp.md", budget_usd: 2.5)
      assert "2.5" in flags
    end

    test "accept string tel quel" do
      flags = SPInjection.build_flags(profile(), sp_path: "/tmp/sp.md", budget_usd: "0.25")
      assert "0.25" in flags
    end

    test "raise ArgumentError sur type invalide (atom, list, etc.)" do
      assert_raise ArgumentError, ~r/budget_usd doit être number\|binary/, fn ->
        SPInjection.build_flags(profile(), sp_path: "/tmp/sp.md", budget_usd: :infinite)
      end

      assert_raise ArgumentError, ~r/budget_usd doit être number\|binary/, fn ->
        SPInjection.build_flags(profile(), sp_path: "/tmp/sp.md", budget_usd: [1, 2])
      end
    end
  end

  describe "build_flags/2 — ordre des flags" do
    test "sequence cohérente : output-format, verbose, sp, brief, allowed, disallowed, budget" do
      flags =
        SPInjection.build_flags(profile(),
          sp_path: "/tmp/sp.md",
          brief_path: "/tmp/brief.md",
          budget_usd: 1.0
        )

      assert flags == [
               "--output-format",
               "stream-json",
               "--verbose",
               "--system-prompt-file",
               "/tmp/sp.md",
               "--append-system-prompt-file",
               "/tmp/brief.md",
               "--allowedTools",
               "Read,Glob",
               "--disallowedTools",
               "web_search",
               "--max-budget-usd",
               "1.0"
             ]
    end
  end
end
