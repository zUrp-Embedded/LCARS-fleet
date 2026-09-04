#!/usr/bin/env bats
# SOURCE: deploy/tests/doctor_honnete.bats
# AUTHOR: bob
# STARDATE: (posee par /push-github)
# STATUS: bats tests — UN VERDICT QUI NE PEUT PAS ETRE VRAI EST PIRE QU'UN VERDICT ABSENT
#
# ─── CE QUE CES TEMOINS TIENNENT ────────────────────────────────────────────────────────────────
#
# Un doctor a DEUX facons de mentir, et les deux ont ete mesurees sur le banc 2004 le 2026-09-01 :
#
#   1. confondre « je ne peux pas le lire » avec « ce n'est pas la ». `66-deck-oidc` annoncait
#      « /etc/lcars/deck-oidc.json absent » d'un fichier de 336 octets present, en `0640
#      root:lcars-system` : un doctor sans sudo ne peut pas l'OUVRIR, il peut parfaitement
#      CONSTATER qu'il est la.
#
#   2. conclure d'une comparaison qui n'a pas eu lieu. `62-runtime-helpers` rendait ONZE drifts
#      « diverge de la source » alors que l'arbre source n'existait pas du tout — `cmp` echoue,
#      et l'echec etait lu comme une divergence.
#
# Et une troisieme, qui n'est pas un mensonge sur un objet mais sur soi : OUBLIER CE QU'ON A FAIT.
# `apply --port-deck 20997` posait le deck sur 20997 ; le `doctor` sans drapeau exigeait 20999.
# Le rail declarait en drift une machine qu'il venait lui-meme de convergir.
#
# ⚠ LE COUT DE CES TROIS N'EST PAS LE FAUX VERDICT, C'EST CE QU'IL APPREND. Un operateur qui voit
# un drift qui ne part jamais cesse de lire le rapport — et le jour ou un vrai drift s'y trouve,
# il est dans la meme liste que les faux.

# shellcheck disable=SC2030,SC2031

load refute

setup() {
  DEPLOY="$BATS_TEST_DIRNAME/.."
  LIB="$DEPLOY/lib/provision-lib.sh"
  RUNNER="$DEPLOY/provision"
  [ -f "$LIB" ] && [ -f "$RUNNER" ]
  export PROVISION_LIB="$LIB"
  # ⚠ EXPORTEE : `lib()` joue dans un `bash -c`, ou une variable non exportee est VIDE. Sans cela
  # `prov_file_state ""` sondait la chaine vide, dont le `dirname` est « . » — toujours traversable,
  # donc toujours « absent ». Le temoin mesurait le repertoire courant de bats.
  export FERME="$BATS_TEST_TMPDIR/ferme"
}

# Joue une fonction de la lib, sans rien d'autre.
lib() { bash -c '. "$1" >/dev/null 2>&1; shift; eval "$@"' _ "$LIB" "$@"; }

teardown() { [ -d "$FERME" ] && chmod 0755 "$FERME" 2>/dev/null || true; }

# ─── LES QUATRE ETATS ───────────────────────────────────────────────────────────────────────────

@test "ETAT : un fichier lisible est « present »" {
  echo x > "$BATS_TEST_TMPDIR/f"
  run lib 'prov_file_state "$BATS_TEST_TMPDIR/f"'
  [ "$output" = present ]
}

@test "ETAT : un fichier qui n'est pas la est « absent » — et l'absence se MERITE" {
  run lib 'prov_file_state "$BATS_TEST_TMPDIR/pas-la"'
  [ "$output" = absent ]
}

@test "ETAT : un fichier PRESENT mais non lisible n'est pas « absent »" {
  # LE DEFAUT, dans sa forme exacte. `0000` reproduit ce que `0640 root:lcars-system` fait a un
  # doctor lance sans sudo : le fichier EST la, ce compte ne peut pas l'ouvrir. La confusion entre
  # les deux etats est ce qui envoyait converger un objet deja pose.
  echo x > "$BATS_TEST_TMPDIR/secret"
  chmod 0000 "$BATS_TEST_TMPDIR/secret"
  run lib 'prov_file_state "$BATS_TEST_TMPDIR/secret"'
  chmod 0644 "$BATS_TEST_TMPDIR/secret"
  [ "$output" = unreadable ]
}

@test "ETAT : sous un repertoire NON TRAVERSABLE, rien n'est conclu" {
  # Un `-e` faux ne prouve l'absence que si l'on peut traverser le parent. Sous un repertoire ferme
  # TOUT parait absent — c'est la facon la plus economique de fabriquer un inventaire faux.
  mkdir -p "$FERME/dedans"
  chmod 0000 "$FERME"
  run lib 'prov_file_state "$FERME/dedans/x"'
  chmod 0755 "$FERME"
  [ "$output" = unmeasurable ]
}

@test "ETAT : les deux etats non concluants DISENT POURQUOI" {
  # « non mesurable » sans le motif est un troisieme verdict aussi opaque que les deux qu'il
  # remplace : l'operateur sait qu'il ne sait pas, et rien de plus.
  echo x > "$BATS_TEST_TMPDIR/secret"; chmod 0000 "$BATS_TEST_TMPDIR/secret"
  run lib 'prov_state_why unreadable "$BATS_TEST_TMPDIR/secret"'
  chmod 0644 "$BATS_TEST_TMPDIR/secret"
  [[ "$output" == *"illisible"* ]]
  [[ "$output" == *"sudo"* ]]                       # et il dit le geste qui leve l'ignorance

  run lib 'prov_state_why unmeasurable /a/b/c'
  [[ "$output" == *"NON MESURABLE"* ]]
  [[ "$output" == *"/a/b"* ]]                       # et il NOMME le repertoire qui bloque
}

@test "ETAT : un chemin dont un ANCETRE lointain est ferme n'est pas dit absent" {
  # La boucle remonte jusqu'au premier ancetre qui EXISTE avant de demander s'il est traversable.
  # Sans elle, un parent absent (sous un grand-parent ferme) rendait `unmeasurable` par accident ou
  # `absent` par optimisme, selon la profondeur — un verdict qui depend de la longueur du chemin.
  mkdir -p "$FERME"
  chmod 0000 "$FERME"
  run lib 'prov_file_state "$FERME/a/b/c/d"'
  chmod 0755 "$FERME"
  [ "$output" = unmeasurable ]
}

# ─── LES MODULES QUI MENTAIENT ──────────────────────────────────────────────────────────────────

@test "66-deck-oidc : un fichier PRESENT et illisible n'est plus annonce « absent »" {
  local mod="$DEPLOY/../runtime/services/forge.d/deck-oidc.sh"
  mkdir -p "$BATS_TEST_TMPDIR/etc"
  echo '{}' > "$BATS_TEST_TMPDIR/etc/deck-oidc.json"
  chmod 0000 "$BATS_TEST_TMPDIR/etc/deck-oidc.json"
  run env LCARS_MODULE_PROTOCOL="$DEPLOY/../runtime/services/lib/module-protocol.sh" LCARS_MODULE_TAG=66-deck-oidc \
          LCARS_DECK_OIDC_FILE="$BATS_TEST_TMPDIR/etc/deck-oidc.json" \
          FORGE_BASE_URL="http://forge.invalid" \
      bash "$mod" check
  chmod 0644 "$BATS_TEST_TMPDIR/etc/deck-oidc.json"
  printf '%s\n' "$output" | refute_out 'deck-oidc\.json absent'
  [[ "$output" == *"illisible"* ]]
}

@test "66-deck-oidc : un fichier VRAIMENT absent reste un DRIFT" {
  # Le sens qui manquait : sans lui, un module qui repondrait « non mesurable » a tout passerait le
  # temoin ci-dessus en ayant cesse de signaler quoi que ce soit.
  local mod="$DEPLOY/../runtime/services/forge.d/deck-oidc.sh"
  run env LCARS_MODULE_PROTOCOL="$DEPLOY/../runtime/services/lib/module-protocol.sh" LCARS_MODULE_TAG=66-deck-oidc \
          LCARS_DECK_OIDC_FILE="$BATS_TEST_TMPDIR/pas-la.json" \
          FORGE_BASE_URL="http://forge.invalid" \
      bash "$mod" check
  [[ "$output" == *"absent"* ]]
  [[ "$output" == *"DRIFT"* ]]
}

@test "62-runtime-helpers : « diverge » exige DEUX cotes" {
  # ONZE drifts par passage sur le banc 2004, tous faux : l'arbre source n'existait pas, `cmp -s`
  # echouait, et l'echec etait lu comme une divergence. Le module ne distinguait pas « different »
  # de « je n'ai pas de quoi comparer ».
  local mod="$DEPLOY/modules.d/62-runtime-helpers.sh"
  grep -q 'r "$SRC_DIR/$n"' "$mod"
  # et ce cas n'est PAS un drift : rien n'a ete mesure, donc rien n'est a converger
  local bloc; bloc="$(sed -n '/r "\$SRC_DIR\/\$n"/,/^    elif/p' "$mod")"
  grep -q 'p_warn'   <<<"$bloc"
  refute grep -q 'p_drift' <<<"$bloc"
}

# ─── LA MACHINE SE RAPPELLE CE QU'ON LUI A DEMANDE ──────────────────────────────────────────────

# `_journal_params` EXTRAITE du runner et jouee seule : c'est elle qui decide, et l'extraire evite de
# faire tourner tout un `provision` pour observer une variable. Elle est ecrite dans un fichier plutot
# que passee par `declare -f` : la fonction lit `$RUNNER`, qu'un sous-shell `env` n'aurait pas.
params() {
  local f="$BATS_TEST_TMPDIR/params.sh"
  { sed -n '/^_journal_params()/,/^}$/p' "$RUNNER"
    echo '_journal_params'
    echo 'printf "%s|%s|%s\n" "${PROV_DECK_PORT:-}" "${PROV_FORGE_BASE:-}" "${PROV_ONLY:-}"'
  } > "$f"
  bash "$f"
}

journal() { printf '%s\n' "$@" > "$BATS_TEST_TMPDIR/journal"; }

@test "MEMOIRE : un port passe a l'apply survit au doctor sans drapeau" {
  journal 'posed_at      2026-09-01' 'params        PROV_DECK_PORT=20997' 'substrate     wsl'
  LCARS_JOURNAL_FILE="$BATS_TEST_TMPDIR/journal" run params
  [[ "$output" == "20997|"* ]]
}

@test "MEMOIRE : un drapeau EXPLICITE gagne toujours sur la memoire" {
  # L'ordre est la propriete : la memoire s'intercale entre le drapeau (deja exporte) et le defaut
  # d'usine (pose plus bas par la lib, en `:=`, qui ne mord que sur du vide). Une memoire qui
  # gagnerait sur un drapeau rendrait la machine impossible a reconfigurer.
  journal 'params        PROV_DECK_PORT=20997'
  LCARS_JOURNAL_FILE="$BATS_TEST_TMPDIR/journal" PROV_DECK_PORT=21001 run params
  [[ "$output" == "21001|"* ]]
}

@test "MEMOIRE : sans journal, rien n'est invente" {
  rm -f "$BATS_TEST_TMPDIR/journal"
  LCARS_JOURNAL_FILE="$BATS_TEST_TMPDIR/journal" run params
  [ "$output" = "||" ]
}

@test "MEMOIRE : la liste est FERMEE — un drapeau du geste n'est pas un fait de la machine" {
  # ⚠ CE QUI SEPARE LES DEUX. `--port-deck` decrit un ETAT-CIBLE ; `--only` et `--verbose` decrivent
  # une INTENTION du geste en cours. Memoriser `--only` ferait qu'un doctor futur n'examinerait plus
  # qu'un module, parce que quelqu'un a un jour lance un apply cible — et le rapport partiel
  # ressemblerait trait pour trait a un rapport complet.
  local liste; liste="$(sed -n 's/^PROV_REMEMBERED=(\(.*\))$/\1/p' "$LIB")"
  [ -n "$liste" ]
  [ "$(wc -w <<<"$liste")" -eq 3 ]
  grep -q 'PROV_DECK_PORT'       <<<"$liste"
  grep -q 'PROV_FORGE_HOST_PORT' <<<"$liste"
  grep -q 'PROV_FORGE_BASE'      <<<"$liste"
  printf '%s\n' "$liste" | refute_out 'ONLY|VERBOSE|PORCELAIN|HUMAN'
}

@test "MEMOIRE : ce que le journal ecrit est ce que la liste fermee autorise" {
  # Les deux bouts du meme contrat : `prov_params_line` ECRIT, `_journal_params` LIT. S'ils
  # divergeaient, la machine se rappellerait de choses que personne n'a decide de lui confier.
  run env PROV_DECK_PORT=20997 PROV_FORGE_BASE=zoe PROV_VERBOSE=1 PROV_HUMAN=quelquun \
      bash -c '. "$1" >/dev/null 2>&1; prov_params_line' _ "$LIB"
  [[ "$output" == *"PROV_DECK_PORT=20997"* ]]
  [[ "$output" == *"PROV_FORGE_BASE=zoe"* ]]
  printf '%s\n' "$output" | refute_out 'PROV_VERBOSE|PROV_HUMAN'
}

# ─── UN ETAT NORMAL N'EST PAS UN DRIFT ──────────────────────────────────────────────────────────

@test "63-forge-tokens : un humain pas encore membre de l'org n'est pas un DRIFT" {
  # ⚠ LE CANON DU 2026-08-30 : le rail pose les AUTORITES — siege, admin de forge, master token,
  # comptes de service ; les PERSONNES s'inscrivent sur la forge et un proprietaire d'org les
  # ajoute. Un humain pas encore membre est donc l'etat NORMAL d'une machine fraiche.
  #
  # Le mot engage : un drift promet qu'`apply` converge. Ici `apply` ne peut RIEN faire — il n'a pas
  # les credentials de la personne, et les avoir serait le contraire du canon.
  local mod="$BATS_TEST_DIRNAME/../../runtime/services/forge.d/tokens.sh"
  local bloc; bloc="$(sed -n '/case "\$(member_state "\$LCARS_LOGIN")"/,/esac/p' "$mod")"
  [ -n "$bloc" ]
  refute grep -q 'p_drift' <<<"$bloc"
  [ "$(grep -c 'p_warn' <<<"$bloc")" -eq 2 ]
  # et chacun NOMME le geste qui le leve — un warn muet est juste un drift plus poli
  grep -q 'profil forge'      <<<"$bloc"
  grep -q 'proprietaire d.org\|propriétaire d.org' <<<"$bloc"
}

@test "63-forge-tokens : ce que le rail PEUT converger reste un drift" {
  # Le sens qui manquait. `63-forge-tokens` porte de vrais drifts — structure absente, tokens a re-minter —
  # et les passer tous en warn aurait rendu le module incapable de signaler quoi que ce soit.
  local mod="$BATS_TEST_DIRNAME/../../runtime/services/forge.d/tokens.sh"
  [ "$(grep -c 'p_drift' "$mod")" -ge 5 ]
}

# ─── LES DEUX SITES QUE LA CAMPAGNE 2007 A TROUVES ──────────────────────────────────────────────
#
# ⚠ CE QUI LES A REVELES : une session FRAICHE. Sur le banc 2001, `bob` etait deja effectivement
# dans le groupe `fleet`, donc il lisait `/opt/lcars/runtime` (0750 root:fleet) et
# `/etc/lcars/services.env` (0640 root:fleet). Sur 2007, l'adhesion venait d'etre posee et n'etait
# pas encore effective dans la session — et les deux sondes ont declare ABSENT ce qu'elles ne
# pouvaient simplement pas ouvrir. Le cas juste est la session fraiche, pas l'inverse.

@test "60-deploy : un prefixe non traversable ne rend pas « release absente »" {
  local mod="$DEPLOY/modules.d/60-deploy.sh"
  local bloc; bloc="$(sed -n '/^check()/,$p' "$mod" | grep -vE '^\s*#')"
  grep -q 'prov_file_state "$PROV_PREFIX"' <<<"$bloc"
  # la garde vient AVANT le drift, sinon elle ne sert a rien
  local n_garde n_drift
  n_garde="$(grep -n 'NON MESURABLE' <<<"$bloc" | head -1 | cut -d: -f1)"
  n_drift="$(grep -n 'release absente sous' <<<"$bloc" | head -1 | cut -d: -f1)"
  [ -n "$n_garde" ] && [ -n "$n_drift" ]
  [ "$n_garde" -lt "$n_drift" ]
}

@test "64-services : un services.env illisible ne rend pas « aucun LCARS_SYSADMIN_UID »" {
  # Un champ vide a DEUX causes quand le fichier est 0640 root:fleet : il n y est pas, ou on ne
  # peut pas le lire. Une seule des deux est un drift.
  local mod="$DEPLOY/modules.d/64-services.sh"
  local bloc; bloc="$(sed -n '/^probe_seat_uid()/,/^}$/p' "$mod" | grep -vE '^\s*#')"
  grep -q 'prov_file_state "$SERVICES_ENV"' <<<"$bloc"
  local n_garde n_drift
  n_garde="$(grep -n 'non sondable' <<<"$bloc" | head -1 | cut -d: -f1)"
  n_drift="$(grep -n 'aucun LCARS_SYSADMIN_UID' <<<"$bloc" | head -1 | cut -d: -f1)"
  [ -n "$n_garde" ] && [ -n "$n_drift" ]
  [ "$n_garde" -lt "$n_drift" ]
}
