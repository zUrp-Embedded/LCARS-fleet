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
        kind: "CapabilityProfile",
        metadata: %{"name" => "x"},
        spec: %{}
      }

      flags = SPInjection.build_flags(cp, sp_path: "/tmp/sp.md")
      assert "--allowedTools" in flags
      assert "--disallowedTools" in flags
    end
  end

  # R0.8-brick4 : describe "build_flags/2 — budget" retiré entièrement.
  # `:budget_usd` n'est plus une opt, `--max-budget-usd` n'est plus émis
  # (pas d'API = pas de budget). Le timeout de réponse est côté Pod.

  describe "build_flags/2 — ordre des flags" do
    test "sequence cohérente : output-format, verbose, sp, brief, allowed, disallowed" do
      flags =
        SPInjection.build_flags(profile(),
          sp_path: "/tmp/sp.md",
          brief_path: "/tmp/brief.md"
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
               "web_search"
             ]
    end
  end

  describe "build_flags/3 — mode-aware (DN amendement RCMode, additif /2)" do
    test ":print base = --system-prompt-file seul" do
      assert SPInjection.build_flags(:print, "/sp.md", []) ==
               ["--system-prompt-file", "/sp.md"]
    end

    test ":print + append_sp_path" do
      assert SPInjection.build_flags(:print, "/sp.md", append_sp_path: "/b.md") ==
               ["--system-prompt-file", "/sp.md", "--append-system-prompt-file", "/b.md"]
    end

    test ":remote_control complet (DN test 7 conformance)" do
      assert SPInjection.build_flags(:remote_control, "/sp.md",
               name: "architect",
               resume: "abc123"
             ) ==
               [
                 "remote-control",
                 "--spawn=session",
                 "--system-prompt-file",
                 "/sp.md",
                 "--name",
                 "architect",
                 "--resume",
                 "abc123"
               ]
    end

    test ":remote_control base (name/resume omis si nil/vide)" do
      assert SPInjection.build_flags(:remote_control, "/sp.md", name: nil, resume: "") ==
               ["remote-control", "--spawn=session", "--system-prompt-file", "/sp.md"]
    end

    test ":remote_control + append_sp_path" do
      assert SPInjection.build_flags(:remote_control, "/sp.md", append_sp_path: "/b.md") ==
               [
                 "remote-control",
                 "--spawn=session",
                 "--system-prompt-file",
                 "/sp.md",
                 "--append-system-prompt-file",
                 "/b.md"
               ]
    end

    test "additif : build_flags/2 (cap-profile) toujours fonctionnel" do
      flags = SPInjection.build_flags(profile(), sp_path: "/tmp/sp.md")
      assert ["--output-format", "stream-json" | _] = flags
    end
  end
end
