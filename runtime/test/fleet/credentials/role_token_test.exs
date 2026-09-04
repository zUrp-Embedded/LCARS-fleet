defmodule Fleet.Credentials.RoleTokenTest do
  # async: false — mutates the global `:role_tokens_dir` config.
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias Fleet.Credentials.RoleToken

  setup do
    tmp = Fleet.TestEnv.tmp_path("roletoken-test")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)
    Fleet.TestEnv.put_env_restoring(:lcars_fleet, :credentials_role_tokens_dir, tmp)

    {:ok, dir: tmp}
  end

  # ⚠ CE QUE CES TEMOINS MESURENT A CHANGE DE COTE, ET LE CONTRAT N'A PAS BOUGE.
  #
  # `RoleToken` ouvrait `<dir>/<compte>.gitea_token`. Il le DEMANDE maintenant au service
  # d'autorite (`roles.sock`), qui l'ouvre a sa place — le double de la suite sert depuis le meme
  # repertoire, donc les fixtures sont inchangees.
  #
  # Ce qui a bouge est le VOCABULAIRE du diagnostic : « absent/unreadable » et « empty » decrivaient
  # une lecture de fichier faite ICI. Ce process ne lit plus rien ; il recoit une CAUSE d'un service
  # qui, lui, a regarde. Continuer a epingler l'ancienne formulation ferait passer un temoin sur des
  # mots que plus personne n'ecrit.
  #
  # LE CONTRAT, LUI, EST LE MEME ET RESTE EPINGLE : un jeton, ou `nil`, et jamais un silence.

  test "token present → returned (trimmed)", %{dir: _dir} do
    Fleet.TestEnv.put_role_token!("reviewer", "  tok-abc  \n")
    assert RoleToken.token("reviewer") == "tok-abc"
  end

  # F-029: a missing role token emits a Logger.warning — the degraded state must be OBSERVABLE,
  # never silent (the fail-closed policy lives in RoleIdentity; RoleToken only reports, never a
  # system fallback).
  test "F-029: absent token → nil + Logger.warning nommant la cause", _ctx do
    log = capture_log(fn -> assert RoleToken.token("reviewer") == nil end)
    assert log =~ "no_role_token"
    assert log =~ "reviewer"
    assert log =~ "unavailable"
  end

  # ⚠ LE FICHIER VIDE NE SE DISTINGUE PLUS DU FICHIER ABSENT, ET C'EST DELIBERE DU COTE SERVICE.
  # Les deux rendent `no_role_token` : ils ont le meme remede (« provision apply le minte ») et le
  # meme effet (aucun jeton). Ce qui DOIT rester distinct est ailleurs — une forge muette, une boite
  # sans autorite — parce que ces causes-la ont des remedes opposes. Le temoin garde donc le point
  # qui compte : un fichier vide ne rend JAMAIS une chaine vide qu'un appelant prendrait pour un
  # jeton, et la forge le refuserait en 401 loin d'ici.
  test "F-029: jeton VIDE → nil, jamais une chaine vide", _ctx do
    Fleet.TestEnv.put_role_token!("qualifier", "   \n")
    log = capture_log(fn -> assert RoleToken.token("qualifier") == nil end)
    assert log =~ "no_role_token"
    assert log =~ "qualifier"
  end

  test "invalid role (non path-safe) → nil (unchanged)", _ctx do
    assert RoleToken.token("../etc") == nil
  end

  # 6-030 — LE TEMOIN DU REPERTOIRE ABSENT A DISPARU AVEC SON SUJET, ET CE N'EST PAS UNE PERTE DE
  # COUVERTURE.
  #
  # Il epinglait un indice que `RoleToken` ajoutait en constatant lui-meme que le REPERTOIRE des
  # jetons manquait — « aucun role ne peut signer, ce n'est pas un probleme de role ». Le BEAM ne
  # regarde plus ce repertoire : il ne le lit pas, et apres la fermeture des modes il ne pourra meme
  # plus le traverser. Un temoin qui le ferait encore mesurerait un fait dont ce process n'est plus
  # responsable.
  #
  # Le diagnostic n'est pas perdu, il a change de proprietaire : c'est le service d'autorite qui voit
  # le repertoire, et son refus le dit (`no_role_token`, une ligne de journal par demande, cote
  # service). La regle « le diagnostic appartient a qui a regarde » est exactement ce que 6-030
  # defendait ; elle s'applique maintenant a l'autre bout de la socket.

  describe "la cause remonte, elle ne se fond pas" do
    # ⚠ SANS CE TEMOIN, LE CHANTIER PERD SA PROPRIETE CENTRALE. Une forge muette et une boite sans
    # jeton ont des remedes OPPOSES : la premiere se reessaie telle quelle, la seconde demande un
    # geste d'admin. Les fondre en « pas de jeton » enverrait la moitie des cas au mauvais geste, et
    # le journal ne permettrait plus de les separer apres coup.
    test "une cause distante n'est pas maquillee en jeton absent", _ctx do
      Fleet.TestEnv.put_role_token!("reviewer", "tok-abc")
      Fleet.Test.AuthorityDouble.force_fail(:forge_unreachable)
      on_exit(fn -> Fleet.Test.AuthorityDouble.force_fail(nil) end)

      log = capture_log(fn -> assert RoleToken.token("reviewer") == nil end)

      assert log =~ "forge_unreachable"
      refute log =~ "no_role_token"
    end

    # LE TEMOIN DU TEMOIN : sans lui, un double qui rendrait toujours `forge_unreachable` passerait
    # l'assertion ci-dessus, et le chemin heureux ne serait plus couvert par personne.
    test "sans forcage, le meme jeton est bien servi", _ctx do
      Fleet.TestEnv.put_role_token!("reviewer", "tok-abc")
      assert RoleToken.token("reviewer") == "tok-abc"
    end
  end
end
