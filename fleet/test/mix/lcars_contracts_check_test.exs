defmodule Mix.Tasks.Lcars.Contracts.CheckTest do
  @moduledoc """
  Smoke/regression of the `mix lcars.contracts.check` gate: `run_checks/0` runs against the REAL repo
  (single app `:lcars_fleet` post-collapse — no more umbrella, BND-112) and must pass, all checks
  green. Locks that the anti-hollow-green guards (R0-EVT-012/014: absent residue-target = fail,
  absent events.yaml = fail, malformed seam = fail) introduced no false-red, and that a future
  contract regression breaks this test. The doc-immune `code_match?/4` (BND-111) is locked by the
  dedicated describe below.

  NB: testing the fail-on-absent paths through `run_checks/0` would require it to take a root — a
  test-infra refactor, not done here. It is NOT what stands between this suite and those paths:
  every check is a `check_*(root)` of its own, so a fixture tree reaches them one by one, and the
  describes below do exactly that. The sentence that used to sit here said the refactor was
  required, and that reading is what kept the fail-on-absent branches untested for as long as it
  stood.
  """
  use ExUnit.Case, async: true

  # JG-097 — LE PERIMETRE ETAIT GARDE, LA POPULATION NON. `tree_scope/1` repond « fleet/deploy
  # est-il dans cet artefact », et c'est tout ce qui etait verifie. Or la population vient de DEUX
  # racines (`deploy/modules.d` et `etc`), une seule est scopee, et `Path.wildcard` sur un chemin
  # absent rend `[]` en silence : un `deploy/` present avec un `modules.d/` vide ou deplace donnait
  # `offenders == []` donc `:pass`, sans avoir ouvert un seul fichier — indistinguable en sortie
  # d'un vert gagne sur onze sourcers conformes.
  #
  # Le commentaire de la fonction nommait deja le risque (« a green that checked nothing ») et le
  # depot porte deja la parade (`measured_nothing?/1` + `broken_result/2`, BL-6-70) ; ce contrat ne
  # l'utilisait pas.
  #
  # Les deux tests vont par paire : sans le second, supprimer la mesure suffirait a rendre le
  # premier vert.
  describe "shell.sourcers_set_strict — la POPULATION fait partie du contrat" do
    defp fixture_root!(ctx) do
      root = Path.join(System.tmp_dir!(), "jg097-#{ctx}-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join([root, "deploy", "modules.d"]))
      File.mkdir_p!(Path.join(root, "etc"))
      on_exit(fn -> File.rm_rf(root) end)
      root
    end

    test "aucun fichier lu → INSTRUMENT BROKEN, jamais un vert" do
      root = fixture_root!("vide")

      result = Mix.Tasks.Lcars.Contracts.Check.check_sourcers_set_strict(root)

      assert result.status == :fail,
             "un contrat qui n'a ouvert aucun fichier a rendu #{result.status}"

      assert Enum.any?(result.evidence, &(&1 =~ "INSTRUMENT BROKEN"))
    end

    test "population NON vide et conforme → pass (le garde n'a pas rendu le contrat impossible)" do
      root = fixture_root!("conforme")

      File.write!(Path.join([root, "deploy", "modules.d", "10-x.sh"]), """
      #!/usr/bin/env bash
      set -euo pipefail
      . "$(dirname "$0")/../lib/provision-lib.sh"
      """)

      result = Mix.Tasks.Lcars.Contracts.Check.check_sourcers_set_strict(root)

      assert result.status == :pass
      assert result.note =~ "1 shell file(s) scanned"
    end
  end

  # JG-088 — L'ABSENCE ETAIT UNE PREUVE NOMMEE, L'ILLISIBILITE UN VERT. `residue_check/2` gardait
  # `File.exists?/1`, vrai pour un fichier PRESENT ET ILLISIBLE : le flux partait alors dans la
  # branche de lecture, ou l'erreur avalee devenait zero ligne, donc zero residu, donc `:pass`. Le
  # contrat declarait l'absence de residu sur un fichier qu'il n'avait pas pu ouvrir.
  #
  # Le cas d'illisibilite est joue avec un REPERTOIRE a la place du fichier (`:eisdir`) et non un
  # `chmod 000` : l'erreur ne depend alors ni de l'uid qui lance la suite (root lit un 000) ni du
  # umask du runner. Le premier test est le temoin — sans lui, on ne saurait pas que le second
  # echoue pour la bonne raison plutot que parce que le contrat echoue toujours.
  describe "residue_check — un mur ne rend pas compte d'un fichier qu'il n'a pas lu" do
    setup do
      root = Path.join(System.tmp_dir!(), "jg088-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join([root, "lib", "fleet"]))
      on_exit(fn -> File.rm_rf(root) end)
      %{root: root, target: Path.join([root, "lib", "fleet", "sp_builder.ex"])}
    end

    test "cible ABSENTE → fail nomme (temoin : la garde d'origine tient toujours)", %{root: root} do
      result = Mix.Tasks.Lcars.Contracts.Check.check_capprofile_lifetime_scope_path(root)

      assert result.status == :fail
      assert Enum.any?(result.evidence, &(&1 =~ "MISSING(enoent)"))
    end

    test "cible ILLISIBLE → fail, pas un vert", %{root: root, target: target} do
      File.mkdir_p!(target)

      result = Mix.Tasks.Lcars.Contracts.Check.check_capprofile_lifetime_scope_path(root)

      assert result.status == :fail,
             "un contrat a declare l'absence de residu sur un fichier qu'il n'a pas pu lire " <>
               "(rendu #{result.status})"

      assert Enum.any?(result.evidence, &(&1 =~ "MISSING(eisdir)"))
    end

    test "cible LISIBLE et sans residu → pass (la garde n'a pas rendu le contrat impossible)", %{
      root: root,
      target: target
    } do
      File.write!(target, """
      defmodule Fleet.SPBuilder do
        def compose_claude_md(cap_profile) do
          get_in(cap_profile.spec, ["invocation", "lifetime_scope"])
        end
      end
      """)

      result = Mix.Tasks.Lcars.Contracts.Check.check_capprofile_lifetime_scope_path(root)

      assert result.status == :pass, "evidence: #{inspect(result.evidence)}"
    end

    # Le meme defaut vivait dans `grep_lines/2`, donc sous TOUS ses appelants — dont trois murs
    # d'absence-de-violation qui globbent des fichiers REELS (`coord.backend.wired_or_pure`,
    # `cowboy.no_bypass`, `gatekeeper.not_an_ordering_step`). Un fichier illisible y produisait zero
    # preuve, c'est-a-dire la conformite. Il n'y a pas de reponse vraie a donner sur un fichier
    # qu'on n'a pas ouvert : l'instrument s'arrete. `code_match?/4` est la porte publique qui passe
    # par `grep_lines/2`.
    test "grep_lines : illisible ≠ zero ligne — l'instrument refuse de repondre", %{
      root: root,
      target: target
    } do
      File.mkdir_p!(target)

      assert_raise RuntimeError, ~r/INSTRUMENT BROKEN/, fn ->
        Mix.Tasks.Lcars.Contracts.Check.code_match?(
          root,
          "lib/fleet/sp_builder.ex",
          ~r/anything/
        )
      end
    end

    test "grep_lines : ABSENT rend toujours [] — l'appelant modelise ce cas lui-meme", %{
      root: root
    } do
      refute Mix.Tasks.Lcars.Contracts.Check.code_match?(
               root,
               "lib/fleet/nowhere.ex",
               ~r/anything/
             )
    end
  end

  test "run_checks passes on the real repo + all checks green (hollow-green guards without false-red)" do
    assert {:pass, checks} = Mix.Tasks.Lcars.Contracts.Check.run_checks()

    ids = Enum.map(checks, & &1.id)
    # the two hardened R0-EVT-012/014 checks run
    assert "events.handlers.exist" in ids
    # MIGRATION Z3 (D-19): layering.dependency_graph is REMOVED along with its raw material
    # (in_umbrella edges of the app mix.exs files) — mechanical successor = boundary (Z4).
    # Its verifiable replacement today: boot.order_f8 (order of the root children).
    assert "boot.order_f8" in ids

    fails = Enum.filter(checks, &(&1.status != :pass))
    assert fails == [], "non-green checks: #{inspect(Enum.map(fails, &{&1.id, &1.evidence}))}"
  end

  # BL-6-45 / bench 2026-08-02: the check reads TWO lists outside `fleet`, and the image
  # BUILD stage copies fleet ALONE before running this gate — a fail-closed on their
  # absence broke the image build (measured: `forge.tf: list not readable` inside the Docker
  # build). Absence is scoped at the TREE level: no sibling tree = out of scope, SKIPPED and
  # NAMED in the note; the equality still runs on what the artifact does carry.
  test "sibling-tree lists: checked when the trees are here, SKIPPED-and-NAMED when they are not" do
    {status, checks} = Mix.Tasks.Lcars.Contracts.Check.run_checks()
    lock = Enum.find(checks, &(&1.id == "roles.provisioning_locked"))

    # NOMMER CE QUI TOMBE, pas seulement constater que quelque chose tombe. Mesure du 2026-08-07 :
    # ce test a rougi DANS l'image et pas ici, et son message ne disait que « :fail au lieu de
    # :pass » — donc il a fallu reproduire l'arbre, rejouer la graine et lire la liste d'exclusions
    # a la main pour ne rien trouver. Un assert qui constate sans nommer coute une heure la premiere
    # fois qu'il mord dans un environnement qu'on ne peut pas ouvrir.
    failed = Enum.filter(checks, &(&1.status != :pass))

    assert status == :pass,
           "run_checks a rendu #{status}. Checks non-pass : " <>
             Enum.map_join(failed, " · ", fn c ->
               "#{c.id}=#{c.status} (#{String.slice(to_string(c.note || "—"), 0, 120)})"
             end)

    assert lock.status == :pass

    # The assertion follows the ARTIFACT: a full checkout must check all four lists; a
    # runtime-only one (the image build stage copies fleet alone) must NAME what it
    # could not see — the one thing that must never happen is a silent pass on absent ground.
    # SAME derivation as the check: the runtime root, then its SIBLING tree
    # (test/mix -> la racine Mix = "../..", puis "deploy" — depuis le demenagement `deploy/` est un
    # ENFANT de la racine, plus un frere : le prefixe `../` visait `fleet/` quand la racine etait
    # `fleet/runtime`.)
    #
    # `deploy`, not `provisioning` (2026-08-05): the tofu recipe moved there with the rest
    # of the live provisioning. The old condition kept PASSING after the move — the v1 tree still
    # exists — while the check it mirrors had changed trees. It would have diverged for real the day
    # someone cleaned up `fleet/provisioning/`, which its own README now says is safe. A condition
    # that agrees by coincidence is the same defect as a comment that is true by accident.
    runtime_root = Path.expand("../..", __DIR__)

    if File.dir?(Path.expand("deploy", runtime_root)) do
      refute lock.note =~ "NOT CHECKED"
    else
      assert lock.note =~ "NOT CHECKED"
      assert lock.note =~ "forge.tf"
    end
  end

  describe "code_match?/4 — anti-hollow-green: a marker in PROSE does not count (BND-111)" do
    @tag :tmp_dir
    test "a marker present ONLY in a @moduledoc/@doc → false (no false-green)", %{
      tmp_dir: tmp
    } do
      # The BND-111 trap: the return-value doc NAMES the `{:error, :brief_required}` tuple; if the
      # check greps the tuple without excluding @doc blocks, a regression of the EXECUTABLE guard
      # would stay green as long as the doc remains. We prove here that the tuple in prose ALONE does
      # NOT satisfy the check.
      File.write!(Path.join(tmp, "prose_only.ex"), """
      defmodule ProseOnly do
        @moduledoc \"\"\"
        Returns:
          * `{:error, :brief_required}` — one-shot pod without a brief
        \"\"\"

        @doc \"\"\"
        Otherwise `{:error, :brief_required}`.
        \"\"\"
        def spawn_pod(_), do: :ok
      end
      """)

      refute Mix.Tasks.Lcars.Contracts.Check.code_match?(
               tmp,
               "prose_only.ex",
               ~r/:brief_required/,
               [
                 ~r/:brief_required/,
                 ~r/^\s*\{:error, :brief_required\}/
               ]
             ),
             "a tuple present only in @moduledoc/@doc must NOT count as code"
    end

    @tag :tmp_dir
    test "the SAME marker on an EXECUTABLE line → true (the real guard counts)", %{tmp_dir: tmp} do
      File.write!(Path.join(tmp, "real_guard.ex"), """
      defmodule RealGuard.Doc do
        @moduledoc \"\"\"
        Returns `{:error, :brief_required}` in prose here.
        \"\"\"
      end

      defmodule RealGuard do
        def spawn_pod(opts) do
          if opts[:brief], do: :ok, else: {:error, :brief_required}
        end
      end
      """)

      assert Mix.Tasks.Lcars.Contracts.Check.code_match?(
               tmp,
               "real_guard.ex",
               ~r/:brief_required/,
               [
                 ~r/:brief_required/,
                 ~r/^\s*.*\{:error, :brief_required\}/
               ]
             ),
             "the tuple on the guard's executable line must count"
    end
  end

  describe "labels.awaits_arch_clears_in_flight — the wall that makes the registry irrelevant" do
    defp lib_file(tmp, name, body) do
      dir = Path.join([tmp, "lib", "fleet"])
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, name), body)
    end

    defp verdict(tmp), do: Mix.Tasks.Lcars.Contracts.Check.check_awaits_arch_clears_in_flight(tmp)

    @tag :tmp_dir
    test "a writer that sets the brake WITHOUT releasing the lock is named", %{tmp_dir: tmp} do
      # `awaits-arch` takes the ticket out of dispatch; the in-flight lock left behind is then
      # reclaimed by reconciliation as orphaned, and the ticket re-dispatches into the same wall.
      lib_file(tmp, "brake.ex", """
      defmodule Brake do
        def apply(repo, n), do: forge().add_label(repo, n, Fleet.Labels.awaits_arch(), [])
      end
      """)

      v = verdict(tmp)
      assert v.status == :fail
      assert Enum.any?(v.evidence, &(&1 =~ "brake.ex"))
    end

    @tag :tmp_dir
    test "a writer that releases the lock passes — and the note SAYS what it measured", %{
      tmp_dir: tmp
    } do
      lib_file(tmp, "disciplined.ex", """
      defmodule Disciplined do
        def apply(repo, n) do
          forge().add_label(repo, n, @awaits_arch_label, [])
          forge().remove_label(repo, n, @in_flight_label, [])
        end
      end
      """)

      v = verdict(tmp)
      assert v.status == :pass
      # A count in the note, because a wall that passes on a population of zero reads exactly like
      # a wall that passes on a compliant one.
      assert v.note =~ "1 writer(s) measured"
    end

    @tag :tmp_dir
    test "a file that only READS the label is NOT a writer — the false positive that shipped", %{
      tmp_dir: tmp
    } do
      # The first version asked "does this file mention add_label AND the awaits-arch label?" and
      # flagged the module that lists the arch's escalation inbox: it READS the label to filter
      # issues, and adds an unrelated one. Co-occurrence in a file answers a neighbouring question,
      # and its answer looks exactly like a finding.
      lib_file(tmp, "inbox.ex", """
      defmodule Inbox do
        @awaits_arch_label Fleet.Labels.awaits_arch()
        def list(issues), do: Enum.filter(issues, &(@awaits_arch_label in &1.labels))
        def tag(repo, n), do: forge().add_label(repo, n, Fleet.Labels.destination_workshop(), [])
      end
      """)

      # No writer at all in this tree: the check must say it measured NOTHING rather than pass —
      # and it must not name this file as a violator either, which is the actual regression.
      v = verdict(tmp)
      assert v.status == :fail
      assert v.note == "population empty"
      assert Enum.any?(v.evidence, &(&1 =~ "no site setting awaits-arch found"))
      refute Enum.any?(v.evidence, &(&1 =~ "sets awaits-arch without clearing"))
    end

    @tag :tmp_dir
    test "delegating to unlock/6 counts as releasing the lock", %{tmp_dir: tmp} do
      # `unlock/6` removes the label AND stops the role stopwatch AND emits `step.unlocked`. A site
      # that delegates to it clears the lock without ever naming it — reading only `remove_label`
      # would flag the most disciplined writer of the three.
      lib_file(tmp, "completer.ex", """
      defmodule Completer do
        def apply(repo, n) do
          forge().add_label(repo, n, @awaits_arch_label, [])
          unlock(forge(), repo, n, [], "engineer", :awaiting_arch)
        end
      end
      """)

      assert verdict(tmp).status == :pass
    end
  end

  describe "roles.provisioning_locked hors de son perimetre" do
    @tag :tmp_dir
    test "un arbre SANS `deploy/` : pass, et la note DIT que les placements sont sautes", %{
      tmp_dir: tmp
    } do
      # LE CHEMIN QUE LE GATE DE L'HOTE NE PEUT PAS PRENDRE. L'etage BUILD de l'image copie `fleet/`
      # sans `deploy/` (COPY explicite), donc cette branche n'existe QUE la — et deux fois cette
      # nuit c'est le build qui a attrape ce que l'hote ne pouvait pas voir : d'abord un
      # `fail-closed` sur une recette hors perimetre, puis un `[]` nu la ou un tuple etait attendu.
      # Ce test amene ce chemin sur l'hote.
      root = Path.join(tmp, "sans-deploy")
      File.mkdir_p!(Path.join(root, "priv/catalogue/cap_profile/canon/cap-profiles"))
      File.mkdir_p!(Path.join(root, "priv/catalogue-system/cap_profile/canon/cap-profiles"))

      File.write!(
        Path.join(root, "priv/catalogue/catalogue.yaml"),
        "api_version: 1\nname: fleet\n"
      )

      res = Mix.Tasks.Lcars.Contracts.Check.check_roles_provisioning_locked(root)

      assert res.status in [:pass, :fail], "la verification doit RENDRE, pas exploser"

      assert res.note =~ "placement defaults SKIPPED",
             "une couverture bornee qui ne se dit pas se lit comme une couverture complete"
    end
  end
end
