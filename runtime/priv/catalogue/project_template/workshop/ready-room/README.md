# ready-room — ce que l'humain dépose pour les agents

**Statut** : actif — créé avec le projet

## Ce qu'est cet endroit

La **boîte de dépôt** du deck écrit ici. Un humain choisit ce projet dans l'onglet, envoie un
fichier, et il arrive dans ce répertoire, sur la face atelier : un firmware à décompiler, un jeu de
données, une capture, une archive à examiner.

## Ce que le commit dit

L'**auteur** du commit est l'humain qui a déposé, avec l'adresse de son compte de forge. Le
committer est le compte système de la machine, parce que c'est lui qui pousse : ce conteneur n'a
pas de jeton personnel. Le message porte une remorque `Deposited-by:` et l'empreinte `sha256` du
fichier.

`git log ready-room/` répond donc à « qui a déposé quoi, et quand », sans rien demander à personne.

## Ce qu'il faut savoir avant d'y compter

- **Un fichier du même nom est remplacé.** L'ancien contenu reste dans l'historique du dépôt.
- **Rien ne purge ce répertoire.** Ce qui est déposé pèse sur les clones du projet ; un fichier qui
  a servi se retire par un commit ordinaire.
- **Le dépôt est borné.** Le plafond par fichier est un réglage de la machine, 50 Mo par défaut.
