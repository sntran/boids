# The examples of boids

Games made with the library, and a site that shows them. Each thing
that moves in a game is a boid: one Erlang process with the behavior
`gen_boid`. The site is one Cowboy app, and each boid on a page is a
process of its VM.

- The games are in [`lib/boids_examples/games`](lib/boids_examples/games):
  one module for each game.
- Each game has its tests in [`test/games`](test/games), and all the
  games pass the common test [`test/games_test.exs`](test/games_test.exs):
  each game starts with the library of this repository, runs for two
  seconds, and stops. CI runs these tests at each push, so a change of
  the library that breaks an example fails CI.
- `terminal.exs` and `speed.exs` are scripts of the library: run them
  from the root of the repository with `mix run examples/terminal.exs`.

| Page | What it shows |
|---|---|
| `/` | What the library is, with a flock of birds and a hawk that moves on the page. |
| `/showcases` | The list of the games, with what each one shows of the library. |
| `/showcases/SLUG` | The page of one game. |
| `/playground` | A visitor defines kinds of boids and their rules, and sees them move. |

[beam.com](https://github.com/sntran/BEAM.com) makes one file of the
app, `app.com`. That file runs on a computer, and on Cloudflare Workers
with the BEAM in WebAssembly.

## Run it on this computer

With Mix:

```sh
cd examples
mix deps.get
mix run --no-halt
```

Then open `http://localhost:4000`. `PORT` gives another port.

In the runtime of Cloudflare Workers (`workerd`), with the BEAM in
WebAssembly:

```sh
cd examples
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
cd examples
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
(Workers Builds), with the root directory `examples`, the build command
`npm run build` and the deploy command `npx wrangler deploy`. Cloudflare
then deploys at each push.

## Add a game

1. Write a module in `lib/boids_examples/games` with two behaviors:
   `BoidsExamples.Scene` (it starts the world of the game, tells how the
   page draws each boid, and takes the input of the person) and
   `BoidsExamples.Game` (`info/0`: its slug, its title, what the person
   does, what it shows of the library, an icon, and its place in the
   list).
2. Write its page, `priv/showcases/SLUG.html`. The page connects to the
   socket `/ws/SLUG` with `Boids.scene` of `/assets/scene.js`.
3. Write its tests in `test/games`.

The site finds the new game with no other change: the list of the
showcases, the address of its page and its socket come from `info/0`.
The common test starts it and checks its page.

## How it works

- The old addresses `/game` and `/flight` move to their pages in
  `/showcases`.
- A page opens one WebSocket for its scene (for example `/ws/flock`, `/ws/game` and `/ws/playground`). The server starts one world with its boids for
  that socket, and sends one moment of it at each tick: the position, the
  direction and the kind of each boid. The page draws the moments.
- A scene stops when its socket closes. With no visitor, the VM has no
  world and does no work.
- A scene is a module with the behavior `BoidsExamples.Scene`
  ([`lib/boids_examples/scene.ex`](lib/boids_examples/scene.ex)). The scenes are
  in [`lib/boids_examples/games`](lib/boids_examples/games).
- The game is the example of the library for a boid with a module of
  its own: see [`rock_patrol.ex`](lib/boids_examples/games/rock_patrol.ex).
- Long Flight is the example for rules as data:
  [`long_flight.ex`](lib/boids_examples/games/long_flight.ex). The deck of the person
  is the list of the rules of each bird, and the order of the list is
  the priority of the rules (`combine => priority`). A card adds a
  rule, changes a weight, makes a bird change its rules when it sees a
  hawk, or gives each bird a relation to an elder. A hawk sends a
  message to the bird that it catches, and a bird that is safe or lost
  stops. One process, the director, has the land, the deck and the
  counts of a run.
- Flock Lab waits for a program of the page (the callback `waits/0`):
  [`flock_lab.ex`](lib/boids_examples/games/flock_lab.ex). A block of the kid is one
  rule from a fixed list, and the server checks each block. The levels
  have stars for the goal, the time and the number of blocks.
- Quiet Herd is the example for a state of each boid:
  [`quiet_herd.ex`](lib/boids_examples/games/quiet_herd.ex). The fear of a deer is its
  state, and changes its rules. The data of each boid tells its
  neighbors how fast the fox moves and how afraid a deer is, so fear
  goes from deer to deer with no message.
- Living Land is the example for processes that start and stop all the
  time: [`living_land.ex`](lib/boids_examples/games/living_land.ex). The genes of an
  animal give the weights of its rules, its speed and its sight. An
  animal starts its young as a new process, and a hunter calls the
  process of the grazer that it catches.

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
cd examples
mix test
```
