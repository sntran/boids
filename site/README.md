# The site of boids

A home page, a game and a playground for the library. The site is one
Cowboy app that uses the library: each boid on a page is a process of
its VM.

| Page | What it shows |
|---|---|
| `/` | What the library is, with a flock of birds and a hawk that moves on the page. |
| `/game` | Rock Patrol: a ship in a field of rocks, and a queen with drones that hunt it and shoot at it. A person flies the ship with the keys. |
| `/playground` | A visitor defines kinds of boids and their rules, and sees them move. |

[beam.com](https://github.com/sntran/BEAM.com) makes one file of the
app, `app.com`. That file runs on a computer, and on Cloudflare Workers
with the BEAM in WebAssembly.

## Run it on this computer

With Mix:

```sh
cd site
mix deps.get
mix run --no-halt
```

Then open `http://localhost:4000`. `PORT` gives another port.

In the runtime of Cloudflare Workers (`workerd`), with the BEAM in
WebAssembly:

```sh
cd site
npm install
npm run build
npm run dev
```

## Deploy it to Cloudflare Workers

The Worker has the name `boids` ([`wrangler.jsonc`](wrangler.jsonc)). It
needs no secret. It has one Durable Object, which runs the VM for all
the visitors.

From a computer, with an account of Cloudflare in `wrangler`:

```sh
cd site
npm install
npm run build
npx wrangler deploy
```

From GitHub: the workflow "Deploy the site"
([`.github/workflows/deploy.yml`](../.github/workflows/deploy.yml)) does
the same at each push to `main` that changes the site or the library.
A person can also start it in the tab "Actions". It needs two secrets of
the repository: `CLOUDFLARE_API_TOKEN` (a token that can edit Workers)
and `CLOUDFLARE_ACCOUNT_ID` (the id of the account). Without them, the
workflow does nothing.

From Cloudflare: connect the repository to a Worker in the dashboard
(Workers Builds), with the root directory `site`, the build command
`npm run build` and the deploy command `npx wrangler deploy`. Cloudflare
then deploys at each push.

## How it works

- A page opens one WebSocket for its scene (`/ws/flock`, `/ws/game`,
  `/ws/playground`). The server starts one world with its boids for
  that socket, and sends one moment of it at each tick: the position, the
  direction and the kind of each boid. The page draws the moments.
- A scene stops when its socket closes. With no visitor, the VM has no
  world and does no work.
- A scene is a module with the behavior `BoidsSite.Scene`
  ([`lib/boids_site/scene.ex`](lib/boids_site/scene.ex)). The scenes are
  in [`lib/boids_site/scenes`](lib/boids_site/scenes).
- The game is the example of the library for a boid with a module of
  its own: see [`game.ex`](lib/boids_site/scenes/game.ex).

## The playground

A visitor sends a definition in JSON: the box, the rocks, and the kinds
of boids with their rules. The page `/playground` has the list of the
keys.

- A definition is data, and not code. The site runs no code of a
  visitor.
- A name of a visitor never becomes an atom. The names of the rules and
  of their options come from a fixed list, and a group is a string.
- The library checks the options and the rules. A bad definition gives a
  text for the visitor, and starts no world.

## The settings

| Variable | Default | On Workers | What |
|---|---|---|---|
| `PORT` | `4000` | | The port of the server. |
| `BOIDS_TICK` | `50` | `100` | The milliseconds between two steps of a boid, and between two moments for the page. |
| `BOIDS_SCENES` | `8` | `4` | The scenes at one time. A visitor above this limit gets a text. |
| `BOIDS_MAX` | `120` | `80` | The boids of a scene of the playground. |

The VM in WebAssembly has one processor and no JIT, so the values on
Workers are lower. In `workerd` on a computer, four scenes with 231
boids at one time kept 10 moments in a second, and the VM used 42 MB.
These numbers are not from Cloudflare: measure there before you raise
the limits.

## Tests

```sh
cd site
mix test
```
