#!/usr/bin/env bats
# SOURCE: fleet/deploy/tests/authority_walls.bats
# AUTHOR: bob
# STARDATE: 2026-08-25
# STATUS: actif — les invariants du service d'autorite, tenus par une mesure et non par la discipline
#
# ⚠ POURQUOI UN SECOND FICHIER DE MURS. `adminite_walls.bats` garde les invariants du chantier
# PRECEDENT : le jeton master hors de portee d'un humain, et aucune adminite lue dans `/etc/group`.
# Ceux-ci gardent le chantier d'APRES, qui descend d'un cran : les jetons de ROLE et le repertoire
# qui les porte. Les deux jeux se ressemblent et ne disent pas la meme chose ; les fondre ferait un
# fichier dont personne ne saurait quelle regle il defend.
#
# LES INVARIANTS :
#   1. aucun ecrivain ne pose un mode de GROUPE sur `/home/private` ni sur ce qu'il contient ;
#   2. le repertoire compte autant que les fichiers — un ecrivain qui le rouvre annule les autres ;
#   3. aucun chemin de `/home/private` n'est passe a un process qui ne peut pas l'ouvrir.
#
# ⚠ ON MESURE LE CODE, PAS LA PROSE. Les cicatrices de ce depot NOMMENT ce qu'elles ont retire —
# c'est leur metier, et un mur qui attraperait l'explication d'un defaut interdirait de l'expliquer.
# Chaque balayage retire donc les commentaires avant de compter.

setup() {
  # ⚠ LE CHEMIN EST RESOLU. `$BATS_TEST_DIRNAME/../..` garderait `deploy/tests/` dans la chaine, et
  # l'exclusion `-not -path '*/tests/*'` viderait alors TOUT le perimetre — les murs passeraient au
  # vert sur une liste vide. Le voisin a paye exactement ce defaut ; on ne le rejoue pas.
  REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"          # fleet/
  mapfile -t CODE < <(
    find "$REPO/deploy" "$REPO/services" "$REPO/bin" "$REPO/etc" -type f \
      \( -name '*.sh' -o -name '*.py' -o -name 'lcars' -o -name 'box' \
         -o -name 'provision' -o -name 'Dockerfile' \) \
      -not -path '*/tests/*' 2>/dev/null | sort
  )
  MANIFEST="$REPO/deploy/system.manifest"
}

code_of() { sed 's/#.*//' "$1"; }

# ⚠ AUCUNE ASSERTION NEGATIVE NUE DANS CE FICHIER. Bash EXEMPTE de `set -e` toute commande dont le
# statut est inverse par `!` : une `! grep` qui n'est pas la DERNIERE instruction d'un test est
# INERTE — elle s'execute, elle echoue, et rien ne le remarque. Un mur inerte est pire qu'un mur
# absent : il certifie.
absent() { # absent <motif etendu> <fichier>
  local n; n="$(code_of "$2" | grep -cE -- "$1" || true)"
  [ "$n" -eq 0 ] || {
    echo "MUR rompu — « $1 » present $n fois dans le CODE de $2 :" >&2
    code_of "$2" | grep -nE -- "$1" >&2
    return 1
  }
}

@test "MUR 0: le perimetre n'est pas VIDE — un balayage casse compte zero, comme un sans-faute" {
  # Sans ce garde, un `find` qui ne trouve plus rien (arbre deplace, extension renommee) rendrait
  # tous les murs verts en n'ayant RIEN lu. Une population vide et zero violation se ressemblent
  # exactement dans la sortie ; seul ce test les separe.
  [ "${#CODE[@]}" -gt 30 ] || { echo "perimetre a ${#CODE[@]} fichiers — le balayage est casse" >&2; return 1; }
  printf '%s\n' "${CODE[@]}" | grep -q 'services/forge-gestures.sh'
  printf '%s\n' "${CODE[@]}" | grep -q 'etc/provision-role-tokens.sh'
  printf '%s\n' "${CODE[@]}" | grep -q 'modules.d/25-directories.sh'
}

# ─── MUR 1 — LE REPERTOIRE DES SECRETS N'EST OUVERT A AUCUN GROUPE ──────────────────────────────
#
# ⚠ CE MUR EXISTE PARCE QUE LES FICHIERS NE SUFFISENT PAS. Trois ecrivains posent ce repertoire —
# `25-directories`, `provision-role-tokens`, `put_secret` — et il suffit qu'UN d'eux repose `0750`
# pour que le groupe rentre au premier `provision apply`, quels que soient les modes des fichiers.
# Une CLASSE D'OBJET entiere avait ete inventoriee a moitie au chantier precedent, un cran plus haut.

@test "MUR 1: aucun ecrivain ne pose un mode de groupe sur le repertoire des secrets" {
  local f hits=0
  for f in "${CODE[@]}"; do
    # Un `install -d` / `ensure_dir` / `chmod` dont le mode ouvre le GROUPE (2e chiffre non nul) sur
    # une ligne qui nomme le repertoire des secrets.
    if code_of "$f" | grep -qE '(install -d|ensure_dir|chmod)[^\n]*0[0-7][1-7][0-7][^\n]*(PRIVATE_DIR|TOKENS_DIR|/home/private)'; then
      echo "MUR rompu — mode de groupe sur le repertoire des secrets dans $f :" >&2
      code_of "$f" | grep -nE '(install -d|ensure_dir|chmod)[^\n]*0[0-7][1-7][0-7][^\n]*(PRIVATE_DIR|TOKENS_DIR|/home/private)' >&2
      hits=$((hits + 1))
    fi
  done
  [ "$hits" -eq 0 ]
}

@test "MUR 1 bis: les TROIS ecrivains du repertoire sont bien la — sinon le mur ci-dessus est creux" {
  # GARDE D'INSTRUMENT. Le mur 1 cherche une ABSENCE : il passe au vert si les trois ecrivains ont
  # disparu, ete renommes, ou si le motif ne les matche plus. Ce test-ci compte la POPULATION que le
  # mur est cense surveiller. Sans lui, un refactor qui renomme `install -d` en autre chose rendrait
  # le mur muet, et personne ne le saurait.
  local n
  n="$(grep -cE 'install -d -m 0700' "$REPO/etc/provision-role-tokens.sh" || true)"
  [ "$n" -ge 1 ] || { echo "provision-role-tokens ne pose plus le repertoire" >&2; return 1; }
  n="$(grep -cE 'install -d -m 0700' "$REPO/services/forge-gestures.sh" || true)"
  [ "$n" -ge 1 ] || { echo "put_secret ne pose plus le repertoire" >&2; return 1; }
  grep -qE 'PROV_TOKENS_DIR 0700' "$REPO/deploy/modules.d/25-directories.sh"
}

# ─── MUR 2 — LES SECRETS NE SONT LISIBLES PAR AUCUN GROUPE ──────────────────────────────────────

# ⚠ CE MUR A ETE REECRIT PARCE QUE LE PREMIER NE POUVAIT PAS VOIR, ET IL PASSAIT VERT.
#
# Il cherchait `(chmod|install)…0[0-7][1-7][0-7]…(gitea_token|forge-master|…)` — le mode ET le nom du
# fichier sur UNE ligne. Or ces ecritures sont ATOMIQUES : `chmod 0600 "$tmp"` puis `mv -f "$tmp"
# "$file"`. Le mode et le nom ne sont JAMAIS sur la meme ligne, chez aucun des ecrivains. Le motif
# etait donc structurellement incapable de matcher.
#
# MESURE DU 2026-08-25 : remettre `chmod 0640` dans le minteur n'a fait rougir AUCUN mur. Trouve par
# mutation, pas par relecture — et c'est exactement ce qu'une mutation est la pour trouver. Un mur
# qui certifie sans regarder est pire qu'un mur absent.
#
# ⚖ CE QU'UN MUR TEXTUEL PEUT TENIR ICI, ET CE QU'IL NE PEUT PAS. Le MODE d'un fichier ecrit par
# tmp+mv n'est pas lisible textuellement sans un faux positif par `chmod` legitime voisin
# (`forge-gestures` en pose un `0755` sur son clone jetable, dans le meme fichier). Le mode est donc
# garde FONCTIONNELLEMENT, par `test/provision_role_tokens` qui `stat` le fichier reellement pose.
# Ce mur-ci garde ce qui EST visible : le geste de DONNER un secret a un groupe.
# ⚠ ET IL EST SCOPE AUX ECRIVAINS DE SECRETS, PAS AU DEPOT ENTIER. Premiere ecriture : un `chgrp`
# interdit PARTOUT dans le perimetre. C'etait rouge des le premier passage, sur `55-deck-oidc.sh` —
# qui `chgrp` legitimement son fichier OIDC pour que le deck (`nobody:nogroup`) puisse le lire. Un
# mur qui accuse un geste sain n'est pas severe, il est FAUX, et un mur faux se fait desarmer.
#
# La regle n'a jamais ete « aucun chgrp » : c'est « aucun SECRET DE FORGE donne a un groupe ». Le
# sujet du mur est donc une liste d'ecrivains, et `MUR 2 ter` garde cette liste non vide.
secret_writers() {
  printf '%s\n' \
    "$REPO/etc/provision-role-tokens.sh" \
    "$REPO/services/forge-gestures.sh" \
    "$REPO/deploy/modules.d/48-forge-host.sh" \
    "$REPO/deploy/modules.d/50-forge.sh" \
    "$REPO/deploy/modules.d/25-directories.sh"
}

@test "MUR 2: aucun ecrivain de secret ne donne son objet a un groupe" {
  local f
  while read -r f; do
    absent 'chgrp' "$f"
    absent '(chown|install)[^\n]*(:|-g )(fleet|\$PROV_FLEET_GROUP|\$\{PROV_FLEET_GROUP\})' "$f"
  done < <(secret_writers)
}

@test "MUR 2 ter: les cinq ecrivains de secret existent — sinon le mur ci-dessus lit le vide" {
  # GARDE D'INSTRUMENT. Le mur 2 cherche une ABSENCE sur une liste NOMMEE : un fichier deplace ou
  # renomme le ferait lire un chemin inexistant, `code_of` rendrait vide, et l'absence serait
  # trivialement vraie. Zero violation et zero fichier se ressemblent exactement dans la sortie.
  local f n=0
  while read -r f; do
    [ -f "$f" ] || { echo "ecrivain de secret introuvable : $f" >&2; return 1; }
    n=$((n + 1))
  done < <(secret_writers)
  [ "$n" -eq 5 ]
}

@test "MUR 2 bis: le manifeste declare /home/private FERME, et a son detenteur" {
  # ⚠ LE MANIFESTE N'EST PAS LA SOURCE DES MODES — trois ecrivains le sont, d'ou le mur 1. Il est
  # la DECLARATION, et un `uninstall` s'en sert. Une table qui dirait encore `0750 root:fleet`
  # decrirait une machine qui n'existe plus.
  local row
  row="$(grep -E '^dir[[:space:]]+/home/private[[:space:]]' "$MANIFEST")"
  [ -n "$row" ] || { echo "/home/private n'est plus declare dans le manifeste" >&2; return 1; }
  [[ "$row" == *0700* ]] || { echo "declare non ferme : $row" >&2; return 1; }
  [[ "$row" == *lcars-authority* ]] || { echo "declare sans detenteur : $row" >&2; return 1; }
  [[ "$row" != *fleet* ]] || { echo "le groupe fleet traverse encore : $row" >&2; return 1; }
}

# ─── MUR 3 — AUCUN CHEMIN DE SECRET N'EST DONNE A QUI NE PEUT PAS L'OUVRIR ───────────────────────
#
# ⚠ C'EST LA CASSE QUE LA FERMETURE A FAILLI PRODUIRE, ET ELLE NE SE VOIT PAS EN LISANT UN SEUL
# FICHIER. `forge-gestures.sh cmd_install` passait `FORGE_TOKEN_FILE=<chemin du jeton systeme>` a une
# porte qui tombe en `nobody:fleet`. Ca marchait tant que le fichier etait `0640 root:fleet` ; en
# `0600 lcars-authority`, la porte meurt sur un `:eacces` presente comme « pas de source
# installable » — le mauvais diagnostic pour le mauvais probleme, sur le geste central du chantier
# voisin, et pour la DEUXIEME fois sur ce meme fichier.

@test "MUR 3: aucun FORGE_TOKEN_FILE construit depuis le repertoire des secrets ne part vers une porte" {
  local f
  for f in "${CODE[@]}"; do
    absent 'FORGE_TOKEN_FILE=[^\n]*(PRIVATE_DIR|TOKENS_DIR|/home/private)' "$f"
  done
}

@test "MUR 3 bis: l'entrypoint relaie bien la VALEUR — sinon la porte part sans credential" {
  # GARDE D'INSTRUMENT du mur 3 : il interdit de passer un CHEMIN. Ce qui rend le geste possible est
  # que la valeur, elle, traverse. `env` ne propage que ce qu'on lui NOMME : la variable oubliee ici
  # rendrait une porte sans credential, et son echec accuserait la source du catalogue.
  grep -qE 'FORGE_TOKEN="\$\{FORGE_TOKEN:-\}"' "$REPO/deploy/docker/entrypoint.sh"
  grep -qE 'FORGE_TOKEN="\$sys_tok_value"' "$REPO/services/forge-gestures.sh"
}

# ─── MUR 4 — LA POSTCONDITION MESURE LE DETENTEUR, PAS LE GROUPE ────────────────────────────────

# ─── MUR 5 — AUCUNE REGLE SUDOERS N'ACCORDE ROOT A UN GROUPE ────────────────────────────────────
#
# ⚠ C'ETAIT LE LIEN LE PLUS FIN DU SYSTEME. `%fleet ALL=(root) NOPASSWD:` ouvrait un binaire root a
# TOUT membre d'un groupe que `human-converger` repeuple depuis l'equipe `humans` de la forge,
# toutes les trente secondes. Le droit d'executer du code en root avait donc la peremption d'un
# cache — et se retirer demandait un `pkill`.
#
# Le mur porte sur le DEPOT ENTIER, pas sur le module qui l'a pose : ce qu'on interdit n'est pas
# « que ce fichier-la recommence », c'est qu'un vingt-cinquieme site, ecrit dans six mois par
# quelqu'un qui n'a lu aucune de ces lignes, rouvre le chemin ailleurs.

@test "MUR 5: aucune ligne de CODE n'accorde root a un groupe par sudoers" {
  local f
  for f in "${CODE[@]}"; do
    # `ALL=(root)` est la syntaxe d'une regle. La PROSE qui nomme la regle retiree est legitime —
    # c'est son metier — et `code_of` l'a deja retiree.
    absent 'ALL=\(root\)' "$f"
  done
}

@test "MUR 5 bis: le rail d'outillage ne passe plus par sudo" {
  # GARDE D'INSTRUMENT ET DE SUBSTANCE A LA FOIS. Le mur 5 interdit d'ECRIRE la regle ; celui-ci
  # verifie que l'APPELANT ne la cherche plus. Les deux moities vont par paire : une regle absente
  # avec un appelant qui fait encore `sudo -n` donne un rail mort, pas un rail sur.
  local recon="$REPO/lib/fleet/admiral/toolchain_reconciler.ex"
  [ -f "$recon" ] || { echo "reconciliateur introuvable : $recon" >&2; return 1; }
  local n
  n="$(grep -cE 'System.cmd\("sudo"' "$recon" || true)"
  [ "$n" -eq 0 ] || { grep -nE 'System.cmd\("sudo"' "$recon" >&2; return 1; }
  grep -q 'toolchain.sock' "$recon"
}

@test "MUR 5 ter: le service privilegie n'OUVRE aucun secret" {
  # ⚠ LA MOITIE QUI REND LE RETRAIT DEFENDABLE. Deplacer le geste root derriere une socket ne vaut
  # que si le process qui le porte ne detient rien : sinon on a juste change la porte du meme
  # cumul — privilege ET secrets dans le meme espace d'adressage, ou un defaut escalade ce qu'il
  # vole. C'est la regle qui donne sa forme a tout ce chantier, lue de l'autre cote.
  local svc="$REPO/services/privileged-executor.py"
  [ -f "$svc" ] || { echo "service privilegie introuvable : $svc" >&2; return 1; }
  absent '/home/private' "$svc"
  absent '(MASTER_TOKEN|gitea_token|forge-master|forge-seed)' "$svc"
}

@test "MUR 4: le minteur VERIFIE le proprietaire de ce qu'il vient d'ecrire" {
  # ⚠ LE CONTROLE EST LE JUMEAU DU MODE, ET LES DESYNCHRONISER FAIT ECHOUER CHAQUE COMPTE. Le script
  # posait `chgrp` puis verifiait `stat -c %G`. Passe au proprietaire sans changer le controle, il
  # aurait compare un groupe qui n'est plus pose — donc un `FAIL` par compte, sur des jetons
  # parfaitement valides. C'est une paire, elle se lit comme une paire.
  local src="$REPO/etc/provision-role-tokens.sh"
  grep -qE 'chown "\$OWNER:\$OWNER"' "$src"
  grep -qE 'stat -c %U' "$src"
  absent 'stat -c %G' "$src"
  absent 'chgrp' "$src"
}
