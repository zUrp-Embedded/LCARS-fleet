defmodule Fleet.Spawner.BwrapLaunchContractTest do
  # P1/C9 — filet anti-régression sur le CONTRAT du launcher bwrap (bin/bwrap_launch.sh).
  #
  # Le bind `.claude` de l'humain ramenait TOUT son `.claude` dans le pod, hooks compris
  # (session-startup.sh, agent-guard…). Comme cwd=HOME=POD_DIR, les tiers settings project/local
  # (racine=cwd, autorisés par `--setting-sources project,local`) résolvaient dans ce `.claude` bindé
  # → settings.json humain chargé comme settings projet → hooks exécutés. Le flag ne pouvait rien
  # (la fuite passe par project/local, pas par le tier user qu'il exclut). cf JOURNAL-P1-hooks.md.
  # Le fix : binder UNIQUEMENT `.credentials.json` (refresh OAuth natif préservé, écriture en place),
  # `.claude/` reste pod-owned → 0 settings.json humain → 0 hook. Ce test verrouille ce contrat.
  use ExUnit.Case, async: true

  @script_rel "bin/bwrap_launch.sh"

  defp umbrella_root do
    # Remonte depuis ce fichier jusqu'à trouver bin/bwrap_launch.sh (racine umbrella).
    Path.dirname(__ENV__.file)
    |> Stream.iterate(&Path.dirname/1)
    |> Enum.find(fn dir ->
      dir == "/" or File.exists?(Path.join(dir, @script_rel))
    end)
  end

  setup_all do
    root = umbrella_root()
    script = Path.join(root, @script_rel)
    assert File.exists?(script), "bin/bwrap_launch.sh introuvable depuis #{__ENV__.file}"
    %{src: File.read!(script)}
  end

  test "mode bind : bind UNIQUEMENT .credentials.json (jamais le dir .claude humain entier)", %{
    src: src
  } do
    # La source du bind creds = CLAUDE_DIR/.credentials.json (via HUMAN_CREDS).
    assert src =~ ~r/HUMAN_CREDS="\$CLAUDE_DIR\/\.credentials\.json"/,
           "HUMAN_CREDS doit pointer $CLAUDE_DIR/.credentials.json"

    # Le bind cible .credentials.json dans le .claude pod-owned, pas le répertoire.
    assert src =~
             ~r/--bind\s+"\$HUMAN_CREDS"\s+"\$POD_DIR\/\.claude\/\.credentials\.json"/,
           "AUTH_BIND_ARGS doit binder $HUMAN_CREDS → $POD_DIR/.claude/.credentials.json"

    # Le bind du DIR entier (ancienne fuite) ne doit plus exister.
    refute src =~ ~r/--bind\s+"\$CLAUDE_DIR"\s+"\$POD_DIR\/\.claude"/,
           "le bind du .claude humain ENTIER est interdit (fuite des hooks — C9)"
  end

  test "garde : présence du fichier creds vérifiée en mode bind", %{src: src} do
    # On ne bind pas un fichier inexistant (bwrap échouerait au mount sans message clair).
    assert src =~ ~r/\[\[ -f "\$HUMAN_CREDS" \]\] \|\|.*exit 1/,
           "le launcher doit garder la présence de $HUMAN_CREDS avant le bind (échec clair sinon)"
  end
end
