#!/usr/bin/env bats
# SOURCE: runtime/test/services/forge-recipe/instance/accounts.bats
# AUTHOR: bob
# STARDATE: 2026-09-15
# STATUS: bats tests for services/forge-recipe/instance/accounts.tf — l'adminité que la recette pose, compte par compte
#
# Deux adminités, et la recette n'en porte qu'une : l'ADMIN DE LCARS, un compte site-admin de la forge,
# que lit la porte de `lcars catalogue install`. L'humain de démonstration en est un ; les comptes de
# mécanique (système, rôles) n'en sont pas. L'admin du SYSTÈME, le siège, n'est pas déclaré ici.
#
# Le témoin lit la déclaration : son jeu contre une forge (apply, promotion, second plan sans
# changement) est un banc, décrit dans le message du commit qui l'a posé.

setup() {
  TF="$BATS_TEST_DIRNAME/../../../../services/forge-recipe/instance/accounts.tf"
  [ -f "$TF" ]
}

# admin_of <nom de ressource gitea_user> → la valeur de `admin` dans son bloc, commentaire retiré
admin_of() {
  awk -v r="$1" '
    $0 ~ "^resource \"gitea_user\" \"" r "\"" { dans = 1; next }
    dans && /^}/ { dans = 0 }
    dans { sub(/#.*/, ""); if ($1 == "admin" && $2 == "=") print $3 }
  ' "$TF"
}

@test "l'humain de démonstration est un admin de LCARS : site-admin, posé par la recette" {
  run admin_of human
  [ "$status" -eq 0 ]
  [ "$output" = "true" ] || { echo "gitea_user.human : admin = « $output » — la recette rétrograderait à chaque passe l'humain que la porte de l'exécuteur doit admettre" >&2; return 1; }
}

@test "les comptes de mécanique ne sont pas admins de LCARS : leur pouvoir s'arrête à l'org" {
  local r
  for r in system system_role; do
    run admin_of "$r"
    [ "$status" -eq 0 ]
    [ "$output" = "false" ] || { echo "gitea_user.$r : admin = « $output » — un compte de mécanique site-admin passerait outre toutes les teams" >&2; return 1; }
  done
}

@test "garde d'instrument : chaque bloc gitea_user porte une ligne admin, et le lecteur les voit toutes" {
  local n
  n="$(grep -c '^resource "gitea_user"' "$TF")"
  [ "$n" -eq 3 ] || { echo "$n ressources gitea_user dans $TF : le témoin en attend trois (system, system_role, human)" >&2; return 1; }
  run admin_of inexistant
  [ -z "$output" ]
}
