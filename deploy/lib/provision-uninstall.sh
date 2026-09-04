#!/usr/bin/env bash
# SOURCE: deploy/lib/provision-uninstall.sh
# AUTHOR: bob
# STARDATE: 2026-09-04
# STATUS: PROTO-V2 — la desinstallation (`provision uninstall`) de `provision`, sourcé par lui (lot 10 : le runner ne porte plus que le runner)
#
# Ce fichier n'est pas un programme : `provision` le source apres sa lib, avec ses globales
# (SUBSTRATE, JOURNAL_FILE, SELF, les drapeaux) en place. Il n'a pas de garde `PROVISION_LIB:?`
# parce qu'il n'est lisible que par le runner qui le source.

# ─── uninstall — IL NE CONTIENT AUCUNE LISTE ────────────────────────────────────────────────────
uninstall_run() {
  [[ -r "$MANIFEST_FILE" ]] || die "manifeste introuvable ($MANIFEST_FILE) — un désinstalleur qui devine est plus dangereux qu'un qui s'arrête"

  local rows preserve_roots=() journal_pkgs=() cls trait obj _mode _owner sub
  rows="$(grep -vE '^\s*#|^\s*$' "$MANIFEST_FILE")"

  # ⚠ LA CLASSE SE LIT TOUJOURS DECOUPEE. Un trait qualifie la classe (`anchor:cond`), il ne la
  # remplace pas — comparer la colonne brute a « anchor » ferait tomber la ligne dans le silence du
  # `case`, sans classe et sans erreur. Le seul mode de defaillance d'un suffixe optionnel est muet.
  split_class() { # split_class <colonne 1> — pose `cls` et `trait`
    cls="${1%%:*}"
    trait="${1#*:}"; [[ "$trait" != "$1" ]] || trait=""
  }

  while read -r cls obj _mode _owner sub; do
    split_class "$cls"
    [[ "$cls" == "preserve" ]] && preserve_roots+=("$obj")
  done <<<"$rows"

  preserved() { # preserved <chemin> -> 0 si lui-meme ou un ancetre est preserve
    local p="$1" r
    for r in "${preserve_roots[@]}"; do
      [[ "$p" == "$r" || "$p" == "$r"/* ]] && return 0
    done
    return 1
  }

  # LES COMPTES D'HUMAINS : la carte du convergeur, LUE AVANT TOUT.
  #
  # ⚠ ELLE VIT DANS UN REPERTOIRE QUE CE VERBE RETIRE : la seule source qui sache quels comptes LCARS
  # a materialises est detruite par la passe qui en a besoin. On la lit ici, avant qu'aucun objet ne parte.
  #
  # ⚠ ET LE SIEGE EST DEDANS : `forge_id = 1` est l'operateur lui-meme — pas un compte que LCARS a
  # cree, celui qui a lance l'install. D'ou les DEUX exclusions de l'awk : le retirer supprimerait
  # la personne qui desinstalle.
  local -a persons=()
  local _seat_login; _seat_login="$(prov_seat_from_map 2>/dev/null || true)"
  if [[ -r "${PROV_UID_MAP_FILE:-}" ]]; then
    mapfile -t persons < <(
      awk -F'\t' -v seat="${_seat_login:-}" '$1 != 1 && $3 != "" && $3 != seat { print $3 }' \
        "$PROV_UID_MAP_FILE" 2>/dev/null | sort -u)
  fi

  # LES PROJETS DOCKER : le journal, et lui seul. Leur nom se DERIVE de `PROV_FORGE_PROJECT`,
  # surchargeable par `--forge-project` — aucune table statique ne peut le porter.
  local -a docker_projects=() annexes_gardees=()
  [[ -r "$JOURNAL_FILE" ]] && mapfile -t docker_projects < <(
    awk '$1=="posed_docker"{ $1=""; sub(/^ /,""); print }' "$JOURNAL_FILE" | tr ' ' '\n' | grep -v '^$' | sort -u)

  # ⚠ LA DECISION SE PREND ICI, A LA LECTURE — PAS A L'EXECUTION. C'est l'emplacement de la garde
  # `/home` (A1), et pour la meme raison : ce qui est ECARTE ne doit jamais entrer dans le plan.
  # Une garde posee apres le point de non-retour laisse le plan annoncer une destruction qui
  # n'aura pas lieu — et le plan est justement ce que l'operateur lit AVANT de decider.
  #
  # ⚠ ET C'EST CE QUI REND LE CONTRAT TESTABLE. `--yes` exige root, donc aucune suite ne peut jouer
  # l'execution : une garde qui n'agit que la n'est verifiable que par lecture du code. Ici, le
  # PLAN compte — et un temoin qui compte mord, comme celui du substrat.
  if [[ "$UNINSTALL_ANNEXES" -ne 1 && "${#docker_projects[@]}" -gt 0 ]]; then
    annexes_gardees=("${docker_projects[@]}")
    docker_projects=()
  fi

  # LE DEPOT APT POSE SOUS CONDITION : le journal, et lui seul. Il n'est pose que sur `linux` et
  # seulement si aucun daemon ne repond — une condition qu'aucune ligne statique ne sait porter. Le
  # declarer dans la table autoriserait a detruire le depot d'un operateur qui l'avait deja ; ne
  # rien declarer le laisserait sur la machine pour toujours.
  local -a apt_repo_files=()
  [[ -r "$JOURNAL_FILE" ]] && mapfile -t apt_repo_files < <(
    awk '$1=="posed_apt_repo"{ $1=""; sub(/^ /,""); print }' "$JOURNAL_FILE" | tr ' ' '\n' | grep -v '^$' | sort -u)

  # LES PAQUETS : le journal, et lui seul.
  # Le FAIT « ce journal etait lisible » se capture ici parce qu'il ne le sera plus a la fin : la
  # boucle `dirs` emporte la racine d'install, journal compris, bien avant le bilan de sortie.
  local _journal_lisible=0
  [[ -r "$JOURNAL_FILE" ]] && _journal_lisible=1
  if [[ -r "$JOURNAL_FILE" ]]; then
    mapfile -t journal_pkgs < <(awk '$1=="apt_installed"{ $1=""; sub(/^ /,""); print }' "$JOURNAL_FILE" | tr ' ' '\n' | grep -v '^$' | sort -u)
  fi

  # ─── LE PLAN ──────────────────────────────────────────────────────────────────────────────────
  local -a files=() dirs=() groups=() humans=() accounts=() refuses_home=() refuses_home_j=()
  applies_here() { # applies_here <colonne substrat> -> 0 si cet objet concerne CE substrat
    local col="$1"
    [[ "$col" == "any" ]] && return 0
    [[ ",${col//+/,}," == *",$SUBSTRATE,"* ]]
  }
  # ⚠ UN SEUL PREDICAT, PARCE QUE LE DEFAUT ETAIT D'EN AVOIR UN SEUL SITE. La boucle de la TABLE
  # portait cette garde ; celle du JOURNAL, non — et le journal alimente le MEME plan executable.
  # Deux modules `NEEDS: root` posent sous /home par des primitives qui JOURNALISENT (`30-wsl` :
  # `$home/.config` et un lien ; `45-sudoers-toolchain` : `$home/.claude/skills/system-issues`),
  # donc ces chemins entraient dans le `rm -rf` pendant que le bilan imprimait, deux ecrans plus
  # haut, « JAMAIS retires, par aucun drapeau ». Vu : plan vierge = 0 fichier /
  # 2 dirs ; les trois memes entrees ajoutees au journal = 1 fichier / 4 dirs.
  #
  # Une garde qui vit a UN endroit du plan n'est pas une garde : elle est une propriete du chemin
  # qu'on a relu. Un predicat nomme, lui, se cherche — et son absence dans une quatrieme boucle se
  # voit.
  sous_home() { [[ "$1" == /home || "$1" == /home/* ]]; }

  expand_version() { # expand_version <chemin pouvant porter <version>> -> 0..n chemins reels
    local pat="$1"
    [[ "$pat" == *"<version>"* ]] || { printf '%s\n' "$pat"; return 0; }
    local g; for g in ${pat//<version>/*}; do [[ -e "$g" ]] && printf '%s\n' "$g"; done
  }

  local resolved
  local -a jokers=()
  while read -r cls obj _mode _owner sub; do
    split_class "$cls"
    applies_here "$sub" || continue
    preserved "$obj" && continue
    # `merge` : le fichier est a quelqu'un d'autre, on n'y a POSE qu'une cle. Le retirer detruirait
    # la configuration de son proprietaire pour desinstaller la notre.
    [[ "$trait" == "merge" ]] && continue
    while read -r resolved; do
      [[ -n "$resolved" ]] || continue
      # ⚠ CE QUI VIENT D'UN JOKER SE NOMME DANS LE PLAN : un chemin resolu depuis un motif est
      # precisement celui que l'operateur n'a pas ecrit et ne peut pas deviner. « 4 repertoire(s) »
      # ne se relit pas.
      [[ "$obj" == "$resolved" ]] || jokers+=("$resolved")
      # ⚠ LA GARDE EST DANS LE CODE, PAS DANS LA TABLE, ET C'EST LA DIFFERENCE QUI COMPTE. `preserve`
      # protege ce qu'on a pense a y ecrire ; celle-ci protege `/home` meme quand personne n'y a
      # pense. Une ligne `dir /home/<n'importe quoi>` ajoutee demain — par distraction, ou parce
      # qu'un objet operator-facing semblait y avoir sa place — retomberait sinon dans un `rm -rf`
      # sans qu'aucun relecteur ait a s'en apercevoir. Un perimetre qui depend de la vigilance de
      # celui qui edite la table n'est pas un perimetre.
      if sous_home "$resolved"; then
        [[ "$cls" == "human" ]] && humans+=("$resolved")   # inventaire seul : on le DIT, on n'y touche pas
        [[ "$cls" == "human" ]] || refuses_home+=("$cls $resolved")
        continue
      fi
      case "$cls" in
        anchor|link|runtime) files+=("$resolved") ;;
        dir|prefix)          dirs+=("$resolved") ;;
        group)               groups+=("$resolved") ;;
        human)               humans+=("$resolved") ;;
        account)             accounts+=("$resolved") ;;
      esac
    done < <(expand_version "$obj")
  done <<<"$rows"

  # ─── CE QUE LE JOURNAL SAIT ET QUE LA TABLE A OUBLIE ──────────────────────────────────────────
  # ⚠ LE JOURNAL NE PRIME JAMAIS SUR `preserve` — d'ou le filtre EN PREMIER. C'est la seule classe
  # dont l'autorite est absolue, et un second inventaire ne doit pas la contourner par derriere.
  local -a journal_files=() journal_dirs=()
  if [[ -r "$JOURNAL_FILE" ]]; then
    local _o _known
    while read -r _o; do
      [[ -n "$_o" ]] || continue
      preserved "$_o" && continue
      # `preserved` N'EST PAS UN PERIMETRE : il protege ce qu'on a pense a y ecrire. Voir `sous_home`.
      sous_home "$_o" && { refuses_home_j+=("$_o"); continue; }
      local _k; _known=0
      for _k in ${files[@]+"${files[@]}"} ${dirs[@]+"${dirs[@]}"}; do
        [[ "$_o" == "$_k" || "$_o" == "$_k"/* ]] && { _known=1; break; }
      done
      [[ "$_known" -eq 1 ]] && continue
      journal_files+=("$_o")
    done < <(awk '$1=="posed_file"||$1=="posed_link"{ $1=""; sub(/^ /,""); print }' "$JOURNAL_FILE" \
               | tr ' ' '\n' | grep -v '^$' | sort -u)
    while read -r _o; do
      [[ -n "$_o" ]] || continue
      preserved "$_o" && continue
      sous_home "$_o" && { refuses_home_j+=("$_o"); continue; }
      _known=0
      for _k in ${dirs[@]+"${dirs[@]}"}; do
        [[ "$_o" == "$_k" || "$_o" == "$_k"/* ]] && { _known=1; break; }
      done
      [[ "$_known" -eq 1 ]] && continue
      journal_dirs+=("$_o")
    done < <(awk '$1=="posed_dir"{ $1=""; sub(/^ /,""); print }' "$JOURNAL_FILE" \
               | tr ' ' '\n' | grep -v '^$' | sort -u)
    files+=(${journal_files[@]+"${journal_files[@]}"})
    dirs+=(${journal_dirs[@]+"${journal_dirs[@]}"})
  fi

  mapfile -t dirs < <(printf '%s\n' "${dirs[@]}" | awk '{ print gsub(/\//,"/"), $0 }' | sort -rn | cut -d' ' -f2-)

  echo "${_PC}=== provision uninstall — plan lu dans $(basename "$MANIFEST_FILE") ===${_PN}"
  # ⚠ CES DEUX-LA SE NOMMENT, ILS NE SE COMPTENT PAS : venus du journal, l'operateur ne peut pas les
  # retrouver en relisant la table. Les compter lui cacherait ce qu'il ne peut pas deviner.
  if [[ "${#apt_repo_files[@]}" -gt 0 ]]; then
    printf '  %-10s %s\n' "dépôt apt" "${apt_repo_files[*]} — posés par CETTE install (journal)"
  fi
  if [[ "${#journal_files[@]}" -gt 0 || "${#journal_dirs[@]}" -gt 0 ]]; then
    printf '  %-10s %s\n' "hors table" \
      "${journal_files[*]-}${journal_files[*]+ }${journal_dirs[*]-} — POSÉS par cette install, ABSENTS de la table (journal)"
  fi
  printf '  %-10s %d objet(s)\n' "fichiers" "${#files[@]}"
  printf '  %-10s %d répertoire(s)\n' "dirs" "${#dirs[@]}"
  printf '  %-10s %d groupe(s)\n' "groupes" "${#groups[@]}"
  printf '  %-10s %d compte(s) de service\n' "comptes" "${#accounts[@]}"
  if [[ "${#docker_projects[@]}" -gt 0 ]]; then
    printf '  %-10s %s\n' "docker" "${docker_projects[*]} — ${_PA}DÉTRUITS (--annexes)${_PN} : conteneurs et réseau. Les volumes restent."
  fi
  if [[ "${#journal_pkgs[@]}" -gt 0 ]]; then
    printf '  %-10s %d paquet(s) : %s\n' "apt" "${#journal_pkgs[@]}" "${journal_pkgs[*]}"
  elif [[ ! -r "$JOURNAL_FILE" ]]; then
    printf '  %-10s %s\n' "apt" "${_PA}AUCUN — journal illisible ou absent ($JOURNAL_FILE) : impossible de distinguer ce que LCARS a posé de ce qui était déjà là${_PN}"
  else
    printf '  %-10s %s\n' "apt" "AUCUN — le journal est là et dit que ce rail n'a posé aucun paquet ($JOURNAL_FILE). Rien à retirer."
  fi
  if [[ "${#persons[@]}" -gt 0 ]]; then
    if [[ "$UNINSTALL_HUMANS" -eq 1 ]]; then
      printf '  %-10s %s\n' "comptes h." "${persons[*]} — comptes RETIRÉS, leurs homes RESTENT"
    else
      printf '  %-10s %s\n' "comptes h." "${persons[*]} — LAISSÉS. « --humans » retire les COMPTES ; les homes restent dans tous les cas"
    fi
  fi
  # ⚠ CE COMPTEUR NE PROMET PLUS RIEN, ET C'EST TOUT SON OBJET. Il disait « N objet(s) dans les homes
  # (--humans) », donc « ce drapeau les emporte » — ce qui etait vrai et ne l'est plus. Le dire au
  # passe serait pire que se taire : un operateur qui lit un inventaire le lit comme une liste de ce
  # qui va disparaitre.
  printf '  %-10s %s\n' "homes" "${#humans[@]} objet(s) posés sous /home — JAMAIS retirés, par aucun drapeau"
  # Une ligne de la table qui vise `/home` sans etre de classe `human` est une ligne qui s'est
  # trompee de perimetre. La garde l'ecarte ; se taire ferait croire que la table est appliquee
  # telle qu'elle est ecrite.
  # Les annexes ecartees se NOMMENT, au meme titre que les lignes qui visent /home : un plan qui
  # tait ce qu'il epargne laisse croire qu'il n'a rien vu. Et c'est ce qui rend la garde mesurable
  # depuis le plan — donc testable sans root.
  if [[ "${#annexes_gardees[@]}" -gt 0 ]]; then
    printf '  %-10s %s\n' "annexes" "${_PC}${annexes_gardees[*]} GARDÉES (défaut) — la forge et le runner continuent de tourner.${_PN}"
    printf '             %s\n' "« --annexes » les retire · « bench-down.sh --project <nom> --yes » détruit un banc"
  fi
  if [[ "${#refuses_home[@]}" -gt 0 ]]; then
    printf '  %-10s %s\n' "écartés" "${_PA}${#refuses_home[@]} ligne(s) de la table visent /home et sont IGNORÉES :${_PN}"
    printf '             %s\n' "${refuses_home[@]}"
  fi
  # ⚠ CEUX-CI SE NOMMENT AUSSI, ET LEUR CAUSE N'EST PAS LA MEME. Une ligne de TABLE qui vise /home
  # s'est trompee de perimetre — c'est une faute d'edition. Un objet de JOURNAL sous /home a ete
  # POSE la par un module, legitimement (`30-wsl`, `45-sudoers-toolchain`) : il n'y a rien a
  # corriger en amont, et tout a dire ici, parce que ce sont exactement les objets que la
  # desinstallation LAISSE derriere elle sans que la table en parle.
  if [[ "${#refuses_home_j[@]}" -gt 0 ]]; then
    printf '  %-10s %s\n' "écartés" "${_PC}${#refuses_home_j[@]} objet(s) du JOURNAL sous /home — POSÉS par cette install, JAMAIS retirés :${_PN}"
    printf '             %s\n' "${refuses_home_j[@]}"
  fi
  [[ "${#jokers[@]}" -eq 0 ]] \
    || printf '  %-10s %s\n' "résolus" "${jokers[*]}"
  printf '  %-10s %s\n' "préservé" "${preserve_roots[*]}"

  if [[ "$UNINSTALL_YES" -ne 1 ]]; then
    echo ""
    echo "  ${_PA}RIEN N'A ÉTÉ RETIRÉ.${_PN} Relis ce plan, puis : sudo $SELF uninstall --yes"
    return 0
  fi

  # ─── L'EXÉCUTION ──────────────────────────────────────────────────────────────────────────────
  local o removed=0 kept=0

  # ─── LES UNITES SYSTEMD — ARRETEES AVANT D'ETRE RETIREES ──────────────────────────────────────
  #
  # ⚠ RETIRER LE FICHIER D'UNITE N'ARRETE PAS LE SERVICE : arreter, PUIS retirer. Un service
  # desactive apres l'effacement de son fichier survit jusqu'au reboot, sur une machine que
  # l'operateur croit desinstallee — et `userdel` refuse ensuite son compte, process encore vivant.
  local _unit
  for _unit in "${files[@]}"; do
    case "$_unit" in
      */systemd/system/*.service) ;;
      *) continue ;;
    esac
    command -v systemctl >/dev/null 2>&1 || break
    systemctl disable --now "$(basename "$_unit")" >/dev/null 2>&1 || true
  done


  # ⚠ LES PAQUETS D'ABORD, ET C'EST UNE PROPRIETE D'ORDRE. Le journal vit sous la racine d'install,
  # que la boucle `dirs` emporte au `rm -rf`. Dans un run complet c'est sans effet — il est charge
  # en memoire bien avant. INTERROMPU entre les deux, « sans journal, aucun paquet » gele les
  # paquets DEFINITIVEMENT : le fichier qui disait lesquels retirer n'existe plus.
  for o in "${journal_pkgs[@]}"; do
    run_quiet env DEBIAN_FRONTEND=noninteractive apt-get remove -y "$o" \
      && removed=$((removed + 1)) || echo "  ${_PA}paquet non retiré : $o${_PN}"
  done

  # ⚠ C'EST LA NATURE DE L'OBJET SUR LE DISQUE QUI DECIDE, PAS SA CLASSE DANS LA TABLE : `runtime`
  # porte aussi des repertoires, et un `rm -f` sur un dossier imprime « non retiré » a chaque passage
  # sans jamais rien retirer.
  for o in ${apt_repo_files[@]+"${apt_repo_files[@]}"} "${files[@]}"; do
    if [[ -d "$o" && ! -L "$o" ]]; then
      rm -rf "$o" && removed=$((removed + 1)) || echo "  ${_PA}non retiré : $o${_PN}"
    elif [[ -e "$o" || -L "$o" ]]; then
      rm -f "$o" && removed=$((removed + 1)) || echo "  ${_PA}non retiré : $o${_PN}"
    fi
  done

  # ─── /home NE SE TOUCHE PAS. IL N'Y A PAS DE BLOC ICI, ET IL N'EN REVIENDRA PAS ────────────────
  #
  # Un `for h in /home/*` + `rm -rf` vivait a cet endroit, sous `--humans`. Il portait sa propre
  # mise en garde — « rien ne garantit que ce soit un home d'humain, une racine de travail partagee
  # y vit aussi » — et il gardait le geste quand meme, avec `preserved` pour filet. Un commentaire
  # qui decrit un danger sans le fermer ne ferme rien : vu, ce bloc detruisait les
  # `.lcars` et les `pods` de cinq personnes, plus tout ce que la table ne pensait pas a preserver.
  #
  # LA REGLE EST MAINTENANT LA MEME POUR TOUS LES BINAIRES : ni `rm`, ni `userdel -r`. Elle ne se
  # negocie pas objet par objet, parce que c'est exactement ainsi qu'elle s'etait perdue — un
  # perimetre qui accepte une exception argumentee en accepte une deuxieme.
  #
  # La classe `human` reste LUE, et seulement pour DIRE ce qui reste (voir le bilan) : declarer ce
  # qu'on POSE garde tout son sens, c'est le droit de le RETIRER qui n'existe plus.
  for o in "${dirs[@]}"; do
    [[ -d "$o" ]] || continue
    rm -rf "$o" && removed=$((removed + 1)) || echo "  ${_PA}non retiré : $o${_PN}"
  done
  # ─── LES OBJETS DOCKER — GARDÉS PAR DÉFAUT, DÉTRUITS SUR DEMANDE ──────────────────────────────
  #
  # ⚠ LE DÉFAUT S'EST INVERSÉ, ET C'EST LA MÊME RÈGLE QUE POUR `/home`. Ces projets sont les
  # ANNEXES du § 13 — la forge et le runner CI. La forge est le PET du corpus : elle porte les
  # dépôts, le backlog, et sur WSL elle vit SOUS le substrat (§ 10) — elle survit même à un
  # `wsl --unregister`. Un `uninstall` qui la détruisait rendait la désinstallation du rail plus
  # destructrice que la destruction de la machine.
  #
  # ⚠ ET LE VOCABULAIRE DES GESTES LE DISAIT DÉJÀ (§ 11) : nuke (banc, routine) ≠ désinstallation
  # (déploiement, admin) ≠ reconstruction. Un banc se jette par `bench-down.sh --yes`, qui existe et
  # dont c'est le métier. `uninstall` désinstalle un DÉPLOIEMENT : il n'avait aucune raison
  # d'emporter avec lui une forge que quelqu'un d'autre alimente.
  #
  # Les volumes étaient déjà gardés et nommés ; ce qui tombait était le CONTENEUR, donc le service.
  # Garder les données d'une forge éteinte est un demi-geste : elle ne répond plus.
  # ⚠ AUCUNE GARDE ICI, ET C'EST VOULU : la liste est deja vide quand `--annexes` n'est pas demande.
  # Une seconde garde a cet endroit serait redondante ET nuisible — elle ferait croire que la
  # decision se prend a l'execution, alors qu'elle se prend a la lecture, comme celle de `/home`.
  # ⚠ LA PORTE EST LA SONDE, PAS `command -v docker` (S3, relecture hostile du 2026-09-04). La lib le
  # dit elle-meme : ce predicat se trompe DANS LES DEUX SENS — sous WSL la CLI vit dans un montage
  # hors PATH, et une CLI presente ne prouve pas qu'un daemon reponde. Ce bloc en faisait sa porte,
  # sans jamais poser DOCKER_HOST : « docker absent » sur un daemon qui repondait, et un `docker ps`
  # muet (`2>/dev/null`) sur un endpoint non resolu. Le plan annoncait « DETRUITS », l'execution ne
  # detruisait rien, et le bilan ne le disait pas.
  #
  # ⚠ ET LE REFUS SE PRONONCE UNE FOIS, POUR TOUS LES PROJETS, EN LES NOMMANT. Un `break` au premier
  # projet abandonnait les suivants sans un mot ; ce qui n'est pas retire se COMPTE (`kept`), pour que
  # la ligne « refus » du bilan le porte. `PROV_DOCKER_WHY` nomme le geste (M3) : c'est
  # `docker_denied_geste` qui parle quand la socket refuse cet utilisateur.
  local proj cid vol ids n_ctr n_rm
  kept=$((kept + ${#annexes_gardees[@]}))
  if [[ "${#docker_projects[@]}" -gt 0 ]] && ! docker_endpoint; then
    echo "  ${_PA}docker injoignable — ${#docker_projects[@]} projet(s) laissé(s) entier(s) : ${docker_projects[*]}${_PN}"
    echo "  ${_PA}  $PROV_DOCKER_WHY${_PN}"
    kept=$((kept + ${#docker_projects[@]}))
    docker_projects=()
  fi
  for proj in ${docker_projects[@]+"${docker_projects[@]}"}; do
    # Capturer puis tester : un `docker ps` qui REFUSE (endpoint, droits) n'est pas un projet vide.
    if ! ids="$("$PROV_DOCKER_BIN" ps -aq --filter "label=com.docker.compose.project=$proj" 2>&1)"; then
      echo "  ${_PA}« docker ps » refuse pour « $proj » — projet laissé entier : ${ids:-sans message}${_PN}"
      kept=$((kept + 1))
      continue
    fi
    n_ctr=0; n_rm=0
    while read -r cid; do
      [[ -n "$cid" ]] || continue
      n_ctr=$((n_ctr + 1))
      if "$PROV_DOCKER_BIN" rm -f "$cid" >/dev/null 2>&1; then
        removed=$((removed + 1)); n_rm=$((n_rm + 1))
      else
        kept=$((kept + 1)); echo "  ${_PA}conteneur non retiré : $cid (projet « $proj »)${_PN}"
      fi
    done <<<"$ids"
    if [[ "$n_ctr" -eq 0 ]]; then
      echo "  0 conteneur trouvé pour « $proj » — rien à retirer de ce côté"
    else
      echo "  projet « $proj » : $n_rm/$n_ctr conteneur(s) retiré(s)"
    fi
    if "$PROV_DOCKER_BIN" network inspect "${proj}_default" >/dev/null 2>&1; then
      if "$PROV_DOCKER_BIN" network rm "${proj}_default" >/dev/null 2>&1; then
        removed=$((removed + 1)); echo "  réseau ${proj}_default retiré"
      else
        kept=$((kept + 1)); echo "  ${_PA}réseau ${proj}_default non retiré (un conteneur y est encore attaché ?)${_PN}"
      fi
    else
      echo "  réseau ${proj}_default absent"
    fi
    while read -r vol; do
      [[ -n "$vol" ]] || continue
      kept=$((kept + 1))
      echo "  ${_PC}volume $vol GARDÉ — il porte du travail (les dépôts de la forge). « docker volume rm $vol » si tu en es sûr.${_PN}"
    done < <("$PROV_DOCKER_BIN" volume ls -q --filter "label=com.docker.compose.project=$proj" 2>/dev/null || true)
  done

  # ─── LES COMPTES D'HUMAINS — SOUS `--humans`, ET JAMAIS AUTREMENT ─────────────────────────────
  if [[ "$UNINSTALL_HUMANS" -eq 1 ]]; then
    local per home
    for per in ${persons[@]+"${persons[@]}"}; do
      home="$(getent passwd "$per" 2>/dev/null | cut -d: -f6)"
      if [[ -n "$home" ]] && preserved "$home"; then
        kept=$((kept + 1))
        echo "  ${_PA}compte $per gardé — son home est du travail préservé ($home)${_PN}"
        continue
      fi
      # ⚠ `userdel`, JAMAIS `userdel -r`. Le `-r` emporte le home : c'est un `rm -rf` sous `/home`
      # par un autre binaire, et la regle ne porte pas sur le nom de l'outil. La garde `preserved`
      # ci-dessus ne couvrait que la classe `preserve` — jamais un home ordinaire, c'est-a-dire
      # exactement celui d'une personne.
      if userdel "$per" >/dev/null 2>&1; then
        removed=$((removed + 1))
        echo "  compte $per retiré — ${_PC}son home reste${_PN} ($home)"
      else
        kept=$((kept + 1))
        echo "  ${_PA}compte $per non retiré — « userdel $per » refuse (session ouverte ?)${_PN}"
      fi
    done
  fi

  # ⚠ LES COMPTES AVANT LES GROUPES : `groupdel` refuse un groupe PRIMAIRE d'un compte existant, donc
  # l'inverse laisserait les deux en place.
  for o in "${accounts[@]}"; do
    getent passwd "$o" >/dev/null 2>&1 || continue
    if userdel "$o" >/dev/null 2>&1; then
      removed=$((removed + 1))
    else
      kept=$((kept + 1))
      echo "  ${_PA}compte $o non retiré — « userdel $o » refuse (process encore vivant ?)${_PN}"
    fi
  done
  for o in "${groups[@]}"; do
    getent group "$o" >/dev/null 2>&1 || continue
    # ⚠ ÇA SE VÉRIFIE ICI, PAS DANS `groupdel` : il RÉUSSIT sur un groupe qui possède encore des
    # fichiers, et les laisse avec un GID orphelin que le prochain `groupadd` réattribuera.
    local porteur
    if porteur="$(prov_group_owns_preserved "$o" "${preserve_roots[@]}")"; then
      kept=$((kept + 1))
      echo "  ${_PA}groupe $o gardé — encore porté par du travail préservé ($porteur)${_PN}"
    elif groupdel "$o" >/dev/null 2>&1; then
      removed=$((removed + 1))
    else
      kept=$((kept + 1))
      echo "  ${_PA}groupe $o non retiré — « groupdel $o » refuse (groupe primaire d'un compte ?)${_PN}"
    fi
  done

  echo ""
  printf '  %d objet(s) retiré(s), %d gardé(s) délibérément.\n' "$removed" "$kept"

  # ─── CE QUI RESTE — LE BILAN DE SORTIE, ET IL EST AUSSI IMPORTANT QUE LE PLAN D'ENTREE ────────
  #
  # Le plan d'entree dit ce qui VA partir ; celui-ci dit ce qui EST reste. Les deux ne se deduisent
  # pas l'un de l'autre : entre les deux il y a les refus (« session ouverte »), les gardes, et tout
  # ce que le perimetre ne couvre pas. Sans cette section, un operateur qui vient de desinstaller ne
  # peut connaitre l'etat de sa machine qu'en la fouillant — c'est-a-dire en refaisant a la main le
  # travail que ce script vient de faire, avec moins d'information que lui.
  #
  # ⚠ ELLE NOMME, ELLE NE COMPTE PAS. « 12 objets gardes » n'est pas quelque chose sur quoi on peut
  # agir ; un chemin l'est. C'est la meme raison qui fait nommer les chemins resolus depuis un joker.
  echo ""
  echo "  ${_PC}── CE QUI RESTE SUR CETTE MACHINE ─────────────────────────────${_PN}"
  echo "  ${_PC}travail préservé${_PN}      ${preserve_roots[*]}"
  echo "  ${_PC}sous /home${_PN}           tout — ni un « rm », ni un « userdel -r ». Les homes, leur contenu,"
  echo "                       et les ${#humans[@]} objet(s) que LCARS y a posés."
  # ⚠ LE JOURNAL N'EXISTE PLUS QUAND CETTE LIGNE S'IMPRIME, et c'est pourquoi la question se pose
  # PLUS HAUT. Il vit sous la racine d'install, que la boucle `dirs` vient d'emporter au `rm -rf` :
  # un `-r "$JOURNAL_FILE"` teste ici l'absence que le script vient lui-meme de creer, et tombe
  # toujours dans la branche « la machine portait deja ». C'est la
  # meme cicatrice d'ordre que « les paquets d'abord » — ce fichier meurt en cours de route, donc
  # tout ce qu'on veut en dire se lit AVANT.
  if [[ "${#journal_pkgs[@]}" -eq 0 && "$_journal_lisible" -eq 1 ]]; then
    echo "  ${_PC}paquets apt${_PN}          aucun retiré — le journal disait qu'aucun n'a été posé par ce rail"
  elif [[ "$_journal_lisible" -eq 1 ]]; then
    echo "  ${_PC}paquets apt${_PN}          ceux que la machine portait DÉJÀ (« apt_already » au journal) restent"
  else
    echo "  ${_PC}paquets apt${_PN}          ${_PA}aucun retiré — le journal était illisible ou absent : impossible de distinguer ce que LCARS a posé de ce qui était déjà là${_PN}"
  fi
  # Le cache des catalogues a demenage sous le prefixe ; ce qui reste a l'ancienne
  # adresse est sous /home, donc hors de portee de ce script — et invisible si personne ne le dit.
  [[ -d "$PROV_LEGACY_CATALOGUES_DIR" ]] \
    && echo "  ${_PA}reliquat${_PN}             $PROV_LEGACY_CATALOGUES_DIR (cache d'avant le 2026-09-01) — « rm -rf $PROV_LEGACY_CATALOGUES_DIR » si tu n'en veux plus"
  [[ "$kept" -gt 0 ]] \
    && echo "  ${_PA}refus${_PN}                $kept objet(s) que ce script n'a PAS pu retirer — voir les lignes ci-dessus"
  return 0
}

