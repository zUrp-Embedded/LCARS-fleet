# SOURCE: runtime/services/lcars.bashrc
# AUTHOR: bob
# STARDATE: (posee par /push-github)
# STATUS: le reglage de shell de LCARS — source par un bloc gere, jamais copie sur un fichier d autrui
#
# ─── POURQUOI CE FICHIER EXISTE ─────────────────────────────────────────────────────────────────
#
# ⚠ PAS UNE COPIE DU `.bashrc` DE LA DISTRIBUTION. Un `skel.bashrc` recopie en entier avec trois
# lignes changees ECRASERAIT `/etc/skel/.bashrc` (pose par `62-runtime-helpers`, sur un poste comme
# dans l'image), et une mise a jour de `bash` par la distribution ne l atteindrait plus.
#
# ICI, LCARS N APPORTE QUE CE QUI EST A LUI. Le `.bashrc` de la distribution reste intact ; un bloc
# gere de trois lignes le source, et teste la presence de ce fichier avant de le sourcer.
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
