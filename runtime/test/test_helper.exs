# Single post-collapse helper (merge of the 14 umbrella helpers — migration Z1).
# - `put_env :start_listener`: belt-and-suspenders inherited from the fleet_api helper.
#   config/test.exs already sets it; kept because a test that manipulates the global config must not
#   make the listener bindable by accident (same hermetic invariant, two locks).
# - NO global `exclude: [:r1_seam]`: the exclusion was LOCAL to fleet_api (its red-by-design WS R1
#   test now carries its own `@moduletag skip:`) — event_router's :r1_seam tests run and must keep
#   running.
# - `ensure_all_started` of the ex-workflow OTP app (helper of the umbrella era): covered by the single-app boot in
#   test env — nothing left to start by hand.
# ⚠ `:api_start_listener` A DISPARU AVEC LA SURFACE TCP (2026-08-14). Il n'y a plus rien a eteindre
# ici : le domaine API n'a qu'un listener, le socket de controle, et il ne demarre que si
# `:api_control_socket` est pose — ce que la config de test ne fait pas. L'hermetisme vient d'une
# ABSENCE, pas d'un drapeau qu'il faut penser a mettre a `false`.

# The in-tree `tmp/` @tmp_dir root is SHARED across runners of the
# `fleet` group (multi-human container). A test interrupted (kill -9) or run by another UID could leave a
# non-group-writable dir under the STABLE @tmp_dir path → the next runner's `create_tmp_dir!` fails
# to `rm_rf` it before the test body. Pre-run best-effort sweep: make every leftover under `tmp/`
# group-writable so ANY fleet-group runner can always erase it. Silent on failure (not-owner dirs
# we cannot chmod are exactly the ones a fresh checkout will not have; the sweep is a belt, not a
# gate). The fixtures that chmod a dir read-only restore it synchronously (see pod_test.exs).
_ =
  case File.stat("tmp") do
    {:ok, _} -> System.cmd("chmod", ["-R", "g+rwX", "tmp"], stderr_to_stdout: true)
    _ -> :ok
  end

# Machine prerequisites resolved at RUNTIME into STRUCTURAL exclusions: an integration test
# whose binary is missing must show up as excluded in the bilan, never print "SKIP" and count
# as a green success (a hollow-green is a verdict about a machine, silently reported as a
# verdict about the code).
#
# The resolution belongs HERE and nowhere else. Branching inside a test module body (`if
# System.find_executable(...) do <property> else <hollow test> end`) freezes the verdict at COMPILE
# time on top of the hollow-green: install the binary afterwards and the differential STILL does not
# exist, because nothing recompiles a test file whose source has not changed.
#
# ⚠ ET LES PREREQUIS NE SONT PAS QUE DES BINAIRES. Un arbre FRERE absent (`assets/`, `deploy/`)
# produisait exactement le vert creux que ce bloc existe pour refuser, sous une autre forme : un
# `if File.dir?(...) do <propriete> else IO.puts("hors perimetre") end` DANS le corps du test. Il
# rend VERT, il ne compte nulle part, et le stage `build` de l'image — qui copie `runtime/` SEUL —
# est justement le contexte ou il ne mesure rien. Meme resolution, meme endroit, meme bilan.
missing_prerequisites =
  for {quoi, tag, present?} <- [
        {"curl", :requires_curl, fn -> System.find_executable("curl") != nil end},
        {"git", :requires_git, fn -> System.find_executable("git") != nil end},
        {"assets/ (la marque du depot)", :requires_brand,
         fn -> File.dir?(Path.expand("../../assets/avatars", __DIR__)) end},
        {"bin/lcars-toolchain-converge", :requires_toolchain_script,
         fn -> File.exists?(Path.expand("../bin/lcars-toolchain-converge", __DIR__)) end}
      ],
      not present?.(),
      do: {quoi, tag}

for {quoi, tag} <- missing_prerequisites do
  IO.puts(
    "test_helper: #{quoi} missing on this machine — #{inspect(tag)} tests are EXCLUDED (visible in the bilan)"
  )
end

# LE SERVICE D'AUTORITE, EN DOUBLE, POUR TOUTE LA SUITE.
#
# `Fleet.Credentials.RoleToken.token/1` ne lit plus `<dir>/<compte>.gitea_token` : il le DEMANDE a
# `roles.sock`. Sans ce double, les ~170 temoins qui posent leurs jetons en ecrivant ces fichiers
# echouent tous sur la meme cause — `:authority_unreachable` — c'est-a-dire sur l'ABSENCE DU BANC,
# pas sur ce qu'ils mesurent.
#
# ⚠ UN SEUL PROCESS SUFFIT, ET C'EST UNE PROPRIETE, PAS UNE ECONOMIE. Le double resout
# `:credentials_role_tokens_dir` A CHAQUE REQUETE, exactement comme le vrai service : chaque temoin
# qui pose son propre `tmp` continue donc d'etre servi depuis SON repertoire, sans qu'aucune fixture
# n'ait a changer. Ce qui a change est QUI ouvre le fichier — et c'etait tout l'objet du chantier.
#
# La course sur cette cle de config existait DEJA (`RoleToken.dir/0` la lisait dans le meme
# `Application.get_env` global) : le double ne l'introduit pas, il en herite.
_ = Fleet.Test.AuthorityDouble.start()

ExUnit.start(exclude: Enum.map(missing_prerequisites, fn {_binary, tag} -> tag end))
