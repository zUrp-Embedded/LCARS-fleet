# SOURCE: runtime/services/lcars.bashrc
# AUTHOR: bob
# STARDATE: (posee par /push-github)
# STATUS: le reglage de shell de LCARS — source par un bloc gere, jamais copie sur un fichier d autrui
#
# ─── POURQUOI CE FICHIER EXISTE ─────────────────────────────────────────────────────────────────
#
# ⚠ PAS UNE COPIE DU `.bashrc` DE LA DISTRIBUTION. Un `skel.bashrc` recopie en entier avec trois
# lignes changees ECRASERAIT `/etc/skel/.bashrc` sur les deux rails (`62-runtime-helpers` cote
# poste, un `COPY` cote image), sans sauvegarde de l original : une machine desinstallee garderait
# le squelette de LCARS a la place du sien, pour toujours, et une mise a jour de `bash` par la
# distribution ne l atteindrait plus.
#
# ICI, LCARS N APPORTE QUE CE QUI EST A LUI. Le `.bashrc` de la distribution reste intact ; un bloc
# gere de trois lignes le source. Ce qui est repris a la desinstallation est ce fichier ; le bloc
# survit et devient INERTE, parce qu il teste la presence avant de sourcer — c est ce qui rend le
# geste honnete sans promettre une restauration bit-a-bit qu on ne tiendrait pas.
#
# ⚠ PAS DE `force_color_prompt=yes`, ET CE N EST PAS UN OUBLI : il colorerait le PS1 que Debian
# construit — celui que la ligne du dessous ECRASE de toute facon. Ce serait regler un objet qui
# n existe plus deux lignes plus loin. La couleur de
# `ls`, elle, vient du bloc `dircolors` de la distribution, que ce fichier ne touche pas.

# Le prompt de l humain, deux lignes : identite/chemin, puis l heure et la fleche.
# ⚠ POSE APRES LE PS1 DEBIAN, ET C EST VOULU : il l ecrase. C est aussi pour ca que le titre de
# fenetre xterm — bati sur l ancien PS1, plus haut dans le fichier de la distribution — ne suit pas.
# LCARS_PS1
PS1='\n\[\033[35m\]\u\[\033[30m\]@\[\033[32m\]\h\[\033[30m\]:\[\033[31m\]\w\[\033[0m\]\n[\t] ==> '

# `-h` : les tailles en unites lisibles. La distribution pose `ls -alF` ; c est la seule autre
# difference avec elle.
alias ll='ls -alFh'
