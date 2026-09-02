# SOURCE: fleet/services/forge-recipe/charte.tf
# AUTHOR: consultant
# STARDATE: 2026-08-01
# STATUS: la charte graphique posee PAR `tofu apply` — un appel, pas une declaration
#
# ─── CE QUE CE FICHIER N'EST PAS ────────────────────────────────────────────────────────────────
# Ce n'est PAS de l'etat convergent. Le provider go-gitea/gitea n'expose aucun attribut avatar
# settable — verifie le 2026-08-01 sur la version 0.8.1 : le schema entier ne contient qu'un seul
# attribut nomme « avatar », `gitea_org.avatar_url`, et il est `computed`, donc en lecture seule.
# Poser un avatar reste un upload d'image (POST /user/avatar avec en-tete `Sudo: <compte>`), et
# aucune version du provider ne le declare aujourd'hui.
#
# Ce fichier ne fait donc qu'une chose : APPELER, depuis `tofu apply`, le script qui sait le faire.
# Le gain est ergonomique — un geste au lieu de deux au stand-up d'une forge. Ce qu'il n'apporte
# PAS, et qu'il ne faut pas croire qu'il apporte :
#   - aucune detection de derive : si quelqu'un change un avatar a la main, `tofu plan` ne verra
#     RIEN. Seul `provision-forge-charte.sh --check` sonde l'etat reel.
#   - aucune idempotence declarative : le script est idempotent PAR REASSERTION (il re-poste
#     l'image a chaque run), ce qui n'est pas la meme chose qu'un plan vide.
#   - l'execution est LOCALE : le script et les PNG doivent exister sur la machine qui applique.
# Si le provider expose un jour un attribut avatar, ce fichier disparait au profit d'attributs sur
# les ressources `gitea_user` / `gitea_org` — et ce sera un vrai gain, pas celui-ci.
#
# ─── DECLENCHEMENT ──────────────────────────────────────────────────────────────────────────────
# `triggers_replace` sur la liste des comptes : la charte se re-pose quand la POPULATION change
# (un role ajoute, un role renomme), ce qui est le seul evenement ou elle peut manquer a quelqu'un.
# Elle ne se re-pose pas a chaque apply — un upload de neuf images pour rien, a chaque run, serait
# du bruit sans lecteur.

resource "terraform_data" "charte" {
  # Les comptes doivent EXISTER avant qu'on leur pose une image : `Sudo: <compte>` sur un compte
  # absent rend 404, et le script compterait l'entree en echec.
  # Les comptes de ce module par RESSOURCE (l'arete porte l'ordre) ; ceux du module `instance/` par
  # NOM, puisqu'ils vivent dans un autre etat. La pose reste correcte sans l'arete : le script
  # re-asserte la charte a chaque passe et compte un compte absent comme hors-perimetre, pas comme
  # un echec — un catalogue tiers n'a aucune raison d'avoir les comptes qu'on a dessines.
  # ⚠ `admiral_username` A DISPARU DE CETTE LISTE, ET DU SCRIPT. Le login du master ne se PARAMETRE
  # pas : une instance Gitea a toujours un premier compte, `id = 1`, site-admin par construction —
  # le script le resout lui-meme, pour le badge ET pour le nom du siege, d'une seule resolution
  # (⚖ arbitrage 2026-08-16 : « le compte master se DERIVE »).
  # Il n'a donc rien a declencher ici : ce qui changerait de master changerait la forge, pas une
  # variable de cette recette.
  triggers_replace = [
    join(",", sort([for u in gitea_user.role : u.username])),
    join(",", sort(var.system_roles)),
    var.system_account,
    # L'ORG, PAR SA RESSOURCE ET NON PAR `var.org`, ET LA DIFFERENCE EST UNE ARETE DE GRAPHE.
    # Les deux valeurs sont identiques — `gitea_org.fleet.name = var.org` — mais une VARIABLE ne
    # cree aucune dependance, alors qu'un attribut de ressource en cree une. Avec `var.org`, la
    # charte pouvait tourner AVANT que l'org existe : mesure sur banc du 2026-08-16,
    # `FAIL org:web-demo — POST avatar -> HTTP 404` sur un apply par ailleurs reussi, l'org etant
    # creee dans la meme passe, plus tard.
    #
    # Meme piege que `data "gitea_teams"` lu au PLAN avant l'existence de l'org : dans cette
    # recette, tout ce qui nomme l'org sans passer par sa ressource est un ordre qu'on espere.
    gitea_org.fleet.name,
  ]

  provisioner "local-exec" {
    # `--avatars-dir` n'est pas passe : le defaut du script est <dir du script>/avatars, et
    # `path.module` designe ce meme dossier. Les deux pointent le meme endroit ; le repeter
    # creerait deux verites pour un chemin.
    #
    # PAS de `--admiral` : le script resout le master par `id=1`. L'option reste, pour un appelant
    # qui vise une forge dont le premier compte n'est pas le master (une forge reprise, un import) —
    # mais ce n'est pas le cas de cette recette, qui ne connait pas ce login et n'a pas a l'inventer.
    # `--org` porte le nom du catalogue, et `--catalogue-avatars` le dossier que `catalogue install`
    # a copie a cote de la recette. Le dossier n'existe PAS pour le catalogue de reference : le
    # script l'ignore alors en silence, parce qu'un avatar est facultatif et qu'un catalogue qui
    # n'en livre pas ne doit produire aucun bruit.
    command = "${path.module}/provision-forge-charte.sh --forge ${var.gitea_url} --org ${var.org} --catalogue-avatars ${path.module}/catalogue-avatars"

    # Le master-token passe par l'ENVIRONNEMENT, jamais par la ligne de commande : un argument est
    # visible dans la table des processus de la machine, une variable d'environnement ne l'est que
    # pour le processus et ses enfants. Meme raison que `TF_VAR_gitea_token` cote appelant.
    environment = {
      FORGE_ADMIN_TOKEN = var.gitea_token
    }
  }
}
