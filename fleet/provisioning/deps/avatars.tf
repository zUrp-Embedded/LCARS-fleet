# SOURCE: fleet/provisioning/deps/avatars.tf
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
#     RIEN. Seul `provision-forge-avatars.sh --check` sonde l'etat reel.
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

resource "terraform_data" "avatars" {
  # Les comptes doivent EXISTER avant qu'on leur pose une image : `Sudo: <compte>` sur un compte
  # absent rend 404, et le script compterait l'entree en echec.
  triggers_replace = [
    gitea_user.system.username,
    gitea_user.starfleet.username,
    join(",", sort([for u in gitea_user.role : u.username])),
  ]

  provisioner "local-exec" {
    # `--avatars-dir` n'est pas passe : le defaut du script est <dir du script>/avatars, et
    # `path.module` designe ce meme dossier. Les deux pointent le meme endroit ; le repeter
    # creerait deux verites pour un chemin.
    command = "${path.module}/provision-forge-avatars.sh --forge ${var.gitea_url}"

    # Le master-token passe par l'ENVIRONNEMENT, jamais par la ligne de commande : un argument est
    # visible dans la table des processus de la machine, une variable d'environnement ne l'est que
    # pour le processus et ses enfants. Meme raison que `TF_VAR_gitea_token` cote appelant.
    environment = {
      FORGE_ADMIN_TOKEN = var.gitea_token
    }
  }
}
