<!-- Date: 2026-08-17 · Dernière révision: 2026-08-18 · Statut: README de la BETA livrée, version EN (le jumeau FR est README_fr.md ; le README produit d'avant est conservé en README.md.pre-beta.bak) · Référencé par: le tar de livraison, README.md -->

<a id="top"></a>

# LCARS-fleet — beta

### Firmware-as-a-Service.
*Pas mal non ? C'est français.*

*(En français : [README_fr.md](README_fr.md).)*

An agent fleet that runs on your machine: a git forge, a CI runner, role-bound agents, and a
dashboard — all brought up by one command, in containers, with nothing installed on your host.

> **This is a BETA meant for testing.** It stands up a **disposable** stack: its own forge, its own
> runner, its own accounts. It is not a production deployment and it does not touch any forge you
> already have. Tearing it down leaves nothing behind but the container images.

---

## What you need

Three things, and your distribution almost certainly has all three:

| | why |
|---|---|
| **docker** | everything runs in containers — the box, the forge, the runner |
| **curl** | the bootstrap talks to the forge over HTTP |
| **python3** | it reads the forge's JSON answers |

Nothing else. **No Elixir, no Erlang, no toolchain on your machine** — the runtime is compiled
inside a throwaway build container and only the result is kept.

You also need an **Anthropic account**: the agents are Claude Code processes. If you already use
`claude` on this machine, your credentials are picked up automatically from
`~/.claude/.credentials.json`.

**During the build you need internet** on three fronts: Docker Hub (base images), hex.pm (Elixir
dependencies), and `claude.ai` (the agent binary). A hiccup on any of them fails the build — loudly,
without leaving a half-installed box.

---

## Install

```bash
tar xzf lcars-fleet-beta.tar.gz
cd lcars-fleet

./docker.sh build                            # ~3 GB transient, reclaimable afterwards
fleet/deploy/docker/bench/bench-up.sh        # forge + box + runner, one gesture
```

`build` produces **two** images: the box you will run, and the toolchain twin its CI runner serves.
Both come out of the same Dockerfile, so the second costs a tag, not a build.

The second command is the whole install. It creates a git forge, waits for it, provisions the
accounts and teams, mints the tokens, starts the box, registers a CI runner, and prints what it
built. It is **replayable**: run it again and it converges rather than duplicating.

When it is done it prints a block like this — those are your entry points:

```
banc PRET
  forge     : http://192.168.1.42:21000   (humain lcars / toto32toto32)
  deck      : http://192.168.1.42:20999
  boite     : lcars-nuit-lcars-1   ssh 192.168.1.42:2222
  runner    : ENREGISTRE (1 vu(s) par la forge)
  ecoute    : 0.0.0.0 — OUVERT SUR LE RESEAU. …
  destruire : bench-down.sh --project lcars-nuit
```

The address it prints is **your machine's**, detected at start-up — that is the one to type, from
here or from another machine on the same network.

If it says anything other than `banc PRET`, it names what is missing. It never reports success on a
stack it could not verify.

---

## Getting in

Two accounts exist, and they are **not** interchangeable.

| account | password | what it is |
|---|---|---|
| **`lcars`** | `toto32toto32` | **the human of the fleet.** This is the one you use. It owns projects, talks to the agents, and has a console on the dashboard. |
| **`admiral`** | `toto1234` | **the system administrator.** It owns the box (sudo) and founded the forge. It runs the machine; it does not run the fleet — starting a fleet under it is refused by design. |

⚠ **These passwords are test defaults, written in plain text in this README — and the bench listens
on `0.0.0.0`, so anything that can reach your machine can reach it.** That is deliberate: the point
of this beta is that a friend on the same network opens the dashboard from their own laptop. It is a
choice for a network you trust, and nothing else. To close it back onto this machine alone:

```bash
fleet/deploy/docker/bench/bench-up.sh --bind 127.0.0.1
```

If the address it announces is wrong (several interfaces, a DNS name, a reverse proxy), name it:
`--advertise <ip-or-name>`. Ports move the same way — `--forge-port`, `--deck-port`.

### Three doors

**The dashboard** — `http://<your-ip>:20999`

The main entrance. Log in through the forge (the button is on the landing page). You get your own
web terminal, the state of your fleet, and the list of running agents.

**The forge** — `http://<your-ip>:21000`

A full Gitea. Your projects, their pull requests, their CI runs. Log in as `lcars`.

**SSH** — `ssh lcars@<your-ip> -p 2222`

The same box, in a real terminal. From there:

```bash
fleet_v2 start        # start the fleet
fleet_v2 status       # what it is doing
lcars catalogue list  # which business catalogues this box carries
```

### Installing the demo catalogue

Out of the box you have one catalogue, `fleet`. A second, `web-demo`, is sitting on the forge as a
deposit — `catalogue list` shows it as `disponible`. Installing it is one command:

```bash
lcars catalogue install web-demo
```

That creates its organisation on the forge, its role accounts, its teams, and lays its material on
the box. It is an **admin** gesture: `lcars` can play it because this bench makes it a forge admin,
and the runtime reads that fact from the forge rather than from any local flag.

Once installed, its cards show up next to `fleet`'s when an agent offers you the catalogue for a new
project — and a project's catalogue is fixed for its life, so you are asked rather than guessed for.

---

## Your first project

Everything happens through a conversation with an agent — you do not fill in forms.

1. Open the dashboard and start your console.
2. Run `fleet_v2 start`, then `claude` — you are talking to the fleet's front desk.
3. Ask it for a project. It will show you the **cards** the installed catalogues carry (a card is a
   workflow: who writes, who reviews, whether CI must be green before merge), let you pick one, and
   create the repository, the branches and the working folders.
4. Open a ticket on that project. The fleet picks it up, spawns the agents the card names, and the
   work lands as a pull request judged by the reviewers that card declares.

The runner is already registered, so a project whose card requires green CI actually gets it.

---

## Tearing it down

```bash
fleet/deploy/docker/bench/bench-down.sh --project lcars-nuit
```

Removes the box, the forge, the runner and their volumes. Then, to reclaim the build space:

```bash
docker builder prune -af
```

Your machine is back where it started. Nothing was ever written outside docker.

---

## What this beta does NOT do

Said plainly, because a tool that hides its edges wastes your time:

- **It is not a production deployment.** The forge it creates is disposable and lives on your
  network. Plugging LCARS into a forge you already run is a different path, and it is not in this
  package.
- **The passwords above are fixed defaults.** Fine for a test on your own machine, wrong anywhere
  else.
- **Nothing is deleted for you.** Projects, repositories and containers stay until you remove them.
- **Agents cost tokens.** They are real Claude Code processes running against your account. A fleet
  left running keeps working.
- **It has been exercised on Debian/Ubuntu with Docker.** Other distributions are untested rather
  than unsupported — if it breaks, the failure messages are written to tell you where.

---

## If something goes wrong

The stack is built to say what is missing rather than to look healthy:

```bash
./docker.sh -p lcars-nuit doctor   # what is provisioned, what drifted, and the gesture that fixes it
./docker.sh -p lcars-nuit logs     # the box's own account of its boot
```

⚠ `-p lcars-nuit` is not optional here. `docker.sh` defaults to a project called `lcars`, and the
bench above creates one called `lcars-nuit` — without the flag you would be asking about a
deployment that does not exist. (`bench-up.sh --project <name>` changes it; the teardown line it
prints always carries the right one.)

`bench-up.sh` prints its verdict block even when it fails — the details are what you need to repair
it, so it never swallows them.

---

## What is inside

- **A box** — Debian, one container, running the fleet's runtime (Elixir/OTP) and a web dashboard.
- **A forge** — Gitea, in its own container, with the organisations, teams and machine accounts the
  fleet needs.
- **A runner** — Gitea Actions, registered, so CI is real.
- **Catalogues** — the business definitions: which roles exist, which workflow cards they serve,
  what each agent's system prompt is. A catalogue is **data, not code**. `fleet` ships inside the
  runtime and is always there; `web-demo` is deposited on the forge and installs in one gesture
  (see *Installing the demo catalogue* above).
- **Agents** — Claude Code processes, each in a sandbox that mounts exactly what its role needs.

---

## Licence

See [`LICENSE`](LICENSE) and [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
