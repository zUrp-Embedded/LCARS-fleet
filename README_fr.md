<!-- Date: 2026-08-18 · Dernière révision: 2026-08-18 · Statut: README de la BETA livrée, version FR (le jumeau EN est README_EN.md) · Référencé par: le tar de livraison, README.md -->

<a id="top"></a>

# LCARS-fleet — beta

### Firmware-as-a-Service.
*Pas mal non ? C'est français.*

*(In English: [README_EN.md](README_EN.md).)*

Une flotte d'agents qui tourne sur ta machine : une forge git, un runner CI, des agents tenus par
leur rôle, et un tableau de bord — le tout monté par une commande, en conteneurs, sans rien
installer sur ton système.

> **C'est une BETA, faite pour être essayée.** Elle monte une pile **jetable** : sa forge, son
> runner, ses comptes. Ce n'est pas un déploiement de production, et elle ne touche à aucune forge
> que tu aurais déjà. La détruire ne laisse que les images docker.

---

## Ce qu'il te faut

Trois choses, et ta distribution les a presque certainement toutes les trois :

| | pourquoi |
|---|---|
| **docker** | tout tourne en conteneurs — la boîte, la forge, le runner |
| **curl** | l'amorçage parle à la forge en HTTP |
| **python3** | il lit les réponses JSON de la forge |

Rien d'autre. **Pas d'Elixir, pas d'Erlang, aucun toolchain sur ta machine** — le runtime est
compilé dans un conteneur de build jetable, et seul le résultat est gardé.

Il te faut aussi un **compte Anthropic** : les agents sont des processus Claude Code. Si tu utilises
déjà `claude` sur cette machine, tes credentials sont repris automatiquement depuis
`~/.claude/.credentials.json`.

**Pendant le build il faut du réseau**, sur trois fronts : Docker Hub (images de base), hex.pm
(dépendances Elixir) et `claude.ai` (le binaire de l'agent). Un hoquet sur l'un des trois fait
échouer le build — bruyamment, sans laisser de boîte à moitié installée.

---

## Installer

```bash
tar xzf lcars-fleet-beta.tar.gz
cd lcars-fleet

./docker.sh build                            # ~3 Go transitoires, récupérables ensuite
fleet/deploy/docker/bench/bench-up.sh        # forge + boîte + runner, un seul geste
```

`build` produit **deux** images : la boîte que tu vas faire tourner, et le jumeau toolchain que son
runner CI sert. Les deux sortent du même Dockerfile, donc la seconde coûte une étiquette, pas un
build.

La seconde commande, c'est toute l'installation. Elle crée une forge git, l'attend, provisionne les
comptes et les teams, minte les jetons, démarre la boîte, enregistre un runner CI, et imprime ce
qu'elle a monté. Elle est **rejouable** : relancée, elle converge au lieu de dupliquer.

Quand c'est fini, elle imprime un bloc de ce genre — ce sont tes points d'entrée :

```
banc PRET
  forge     : http://192.168.1.42:21000   (humain lcars / toto32toto32)
  deck      : http://192.168.1.42:20999
  boite     : lcars-nuit-lcars-1   ssh 192.168.1.42:2222
  runner    : ENREGISTRE (1 vu(s) par la forge)
  ecoute    : 0.0.0.0 — OUVERT SUR LE RESEAU. …
  destruire : bench-down.sh --project lcars-nuit
```

L'adresse imprimée est **celle de ta machine**, détectée au démarrage : c'est celle-là qu'on tape,
d'ici ou depuis une autre machine du même réseau.

Si elle dit autre chose que `banc PRET`, elle nomme ce qui manque. Elle n'annonce jamais un succès
sur une pile qu'elle n'a pas pu vérifier.

---

## Entrer

Deux comptes existent, et ils ne sont **pas** interchangeables.

| compte | mot de passe | ce que c'est |
|---|---|---|
| **`lcars`** | `toto32toto32` | **l'humain de la flotte.** C'est celui que tu utilises. Il possède les projets, parle aux agents, et a une console sur le tableau de bord. |
| **`admiral`** | `toto1234` | **l'administrateur système.** Il possède la boîte (sudo) et a fondé la forge. Il fait tourner la machine ; il ne fait pas tourner la flotte — démarrer une flotte sous lui est refusé par construction. |

⚠ **Ces mots de passe sont des défauts de test, écrits en clair dans ce README — et le banc écoute
sur `0.0.0.0`, donc tout ce qui atteint ta machine l'atteint.** C'est délibéré : l'intérêt de cette
beta, c'est qu'un ami sur le même réseau ouvre le tableau de bord depuis son propre portable. C'est
un choix pour un réseau de confiance, et rien d'autre. Pour le refermer sur cette machine seule :

```bash
fleet/deploy/docker/bench/bench-up.sh --bind 127.0.0.1
```

Si l'adresse annoncée est fausse (plusieurs interfaces, un nom DNS, un reverse-proxy), nomme-la :
`--advertise <ip-ou-nom>`. Les ports se déplacent pareil — `--forge-port`, `--deck-port`.

### Trois portes

**Le tableau de bord** — `http://<ton-ip>:20999`

L'entrée principale. On s'y connecte par la forge (le bouton est sur la page d'accueil). Tu y as ton
propre terminal web, l'état de ta flotte, et la liste des agents qui tournent.

**La forge** — `http://<ton-ip>:21000`

Un Gitea complet. Tes projets, leurs pull requests, leurs runs de CI. Connexion en `lcars`.

**SSH** — `ssh lcars@<ton-ip> -p 2222`

La même boîte, dans un vrai terminal. De là :

```bash
fleet_v2 start        # démarrer la flotte
fleet_v2 status       # ce qu'elle fait
lcars catalogue list  # quels catalogues métier cette boîte porte
```

### Installer le catalogue de démo

À la sortie de la boîte tu as un catalogue, `fleet`. Un second, `web-demo`, attend sur la forge sous
forme de dépôt — `catalogue list` l'affiche en `disponible`. L'installer tient en une commande :

```bash
lcars catalogue install web-demo
```

Ça crée son organisation sur la forge, ses comptes de rôle, ses teams, et pose son matériel sur la
boîte. C'est un geste **admin** : `lcars` peut le jouer parce que ce banc en fait un admin de la
forge, et le runtime lit ce fait sur la forge plutôt que dans un drapeau local.

Une fois installé, ses cartes apparaissent à côté de celles de `fleet` quand un agent te propose le
catalogue d'un nouveau projet — et le catalogue d'un projet est fixé pour sa vie, donc la question
t'est posée au lieu d'être devinée.

---

## Ton premier projet

Tout passe par une conversation avec un agent — tu ne remplis pas de formulaire.

1. Ouvre le tableau de bord et démarre ta console.
2. Lance `fleet_v2 start`, puis `claude` — tu parles au guichet de la flotte.
3. Demande-lui un projet. Il te montre les **cartes** que portent les catalogues installés (une
   carte est un workflow : qui écrit, qui relit, si la CI doit être verte avant de merger), te
   laisse en choisir une, et crée le dépôt, les branches et les dossiers de travail.
4. Ouvre un ticket sur ce projet. La flotte le prend, spawn les agents que la carte nomme, et le
   travail arrive en pull request, jugée par les relecteurs que cette carte déclare.

Le runner est déjà enregistré, donc un projet dont la carte exige une CI verte l'obtient vraiment.

---

## Détruire

```bash
fleet/deploy/docker/bench/bench-down.sh --project lcars-nuit
```

Retire la boîte, la forge, le runner et leurs volumes. Puis, pour récupérer l'espace de build :

```bash
docker builder prune -af
```

Ta machine est revenue là où elle était. Rien n'a jamais été écrit hors de docker.

---

## Ce que cette beta ne fait PAS

Dit franchement, parce qu'un outil qui cache ses bords fait perdre du temps :

- **Ce n'est pas un déploiement de production.** La forge qu'elle crée est jetable et vit sur ton
  réseau. Brancher LCARS sur une forge que tu fais déjà tourner est un autre chemin, et il n'est pas
  dans ce paquet.
- **Les mots de passe ci-dessus sont des défauts fixes.** Bien pour un essai sur un réseau de
  confiance, faux partout ailleurs.
- **Rien n'est supprimé pour toi.** Projets, dépôts et conteneurs restent jusqu'à ce que tu les
  retires.
- **Les agents coûtent des tokens.** Ce sont de vrais processus Claude Code sur ton compte. Une
  flotte laissée tourner continue de travailler.
- **Ça a été exercé sur Debian/Ubuntu avec Docker.** Les autres distributions ne sont pas testées
  plutôt que non supportées — si ça casse, les messages d'échec sont écrits pour dire où.

---

## Si quelque chose va de travers

La pile est faite pour dire ce qui manque plutôt que pour avoir l'air en bonne santé :

```bash
./docker.sh -p lcars-nuit doctor   # ce qui est provisionné, ce qui a dérivé, et le geste qui répare
./docker.sh -p lcars-nuit logs     # le récit que la boîte fait de son propre boot
```

⚠ `-p lcars-nuit` n'est pas optionnel ici. `docker.sh` vise par défaut un projet appelé `lcars`, et
le banc ci-dessus en crée un appelé `lcars-nuit` — sans le drapeau, tu interrogerais un déploiement
qui n'existe pas. (`bench-up.sh --project <nom>` le change ; la ligne de destruction qu'il imprime
porte toujours le bon.)

`bench-up.sh` imprime son bloc de verdict même quand il échoue — les détails sont ce qu'il te faut
pour réparer, donc il ne les avale jamais.

---

## Ce qu'il y a dedans

- **Une boîte** — Debian, un conteneur, qui fait tourner le runtime de la flotte (Elixir/OTP) et un
  tableau de bord web.
- **Une forge** — Gitea, dans son propre conteneur, avec les organisations, teams et comptes machine
  dont la flotte a besoin.
- **Un runner** — Gitea Actions, enregistré, pour que la CI soit réelle.
- **Des catalogues** — les définitions métier : quels rôles existent, quelles cartes de workflow ils
  servent, quel est le system prompt de chaque agent. Un catalogue est de la **donnée, pas du code**.
  `fleet` est livré dans le runtime et toujours là ; `web-demo` est déposé sur la forge et s'installe
  en un geste (cf. *Installer le catalogue de démo* plus haut).
- **Des agents** — des processus Claude Code, chacun dans une sandbox qui monte exactement ce dont
  son rôle a besoin.

---

## Licence

Voir [`LICENSE`](LICENSE) et [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
