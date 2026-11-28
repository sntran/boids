# The examples of boids

Games made with the library, and a site that shows them. Each thing
that moves in a game is a boid: one Erlang process with the behavior
`gen_boid`. The site is one Cowboy app, and each boid on a page is a
process of its VM.

- Each game is a folder here, with three files: its module, its page and
  its tests. For example [`rock_patrol`](rock_patrol) has
  `rock_patrol.ex`, `rock_patrol.html` and `rock_patrol_test.exs`.
- The folder [`lib`](lib) has the site: the pages, the socket, and the
  behaviors of a scene and of a game.
- All the games pass the common test [`test/games_test.exs`](test/games_test.exs):
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
the same each time the workflow "CI" is good on `main`: CI has the tests
of the examples and the check of each page on a phone.
A person can also start it in the tab "Actions". It needs two secrets of
the repository: `CLOUDFLARE_API_TOKEN` (a token that can edit Workers)
and `CLOUDFLARE_ACCOUNT_ID` (the id of the account). Without them, the
workflow does nothing.

From Cloudflare: connect the repository to a Worker in the dashboard
(Workers Builds), with the root directory `examples`, the build command
`npm run build` and the deploy command `npx wrangler deploy`. Cloudflare
then deploys at each push.

## Add a game

Make a folder `my_game` here, with three files:

1. `my_game.ex`: a module with `use BoidsExamples.Game` and
   `@behaviour BoidsExamples.Scene`. As a scene, it starts the world of
   the game, tells how the page draws each boid, and takes the input of
   the person. As a game, its `info/0` gives its slug, its title, what
   the person does, what it shows of the library, an icon, and its place
   in the list.
2. `my_game.html`: its page. The page connects to the socket `/ws/SLUG`
   with `Boids.scene` of `/assets/scene.js`. `use BoidsExamples.Game`
   puts the page in the module.
3. `my_game_test.exs`: its tests.

The site finds the new game with no other change: the list of the
showcases, the address of its page and its socket come from `info/0`.
The common test starts it and checks its page.

On a phone in portrait, the scene turns the world of the game (see
[On a phone](#on-a-phone)). The module of the game does not know the
turn, but its page must do these things:

1. **The keys come from data.** The page gives the option `keys` to
   `Boids.scene`, and has no key of its own. The scene makes the keys,
   and changes an arrow of the screen to a direction of the world. For
   another control with an arrow (the signs of Exit Plan), the page uses
   `scene.direction("left")`.
2. **A point of the field comes from `scene.toWorld(event)`.** The page
   does not calculate it from the rectangle of the canvas.
3. **A drawing with a top and a bottom is upright.** The page draws on
   the field with the options `beneath` and `above`, in pixels of the
   world, not on a canvas of its own. A circle or an arrow of the world
   turns with the world, and that is correct. But a text, a stall or a
   lantern has a top and a bottom: draw it with
   `view.upright(x, y, function () { ... })`, where `view` is the last
   argument of `beneath` and `above`. In the function, the point is
   `0, 0`.
4. **A text names a thing, not a direction.** "Reach the far side", not
   "on the right": the right side of the world is the top of a phone.
   This is also for the texts that the module sends (a hint, a label of
   a zone).
5. **The message of the game is in an element** that the page gives as
   the option `message`. On a phone, the scene shows it on the field.
   The button for the end of a level is in the list `mirror` of `keys`:
   a copy of it shows on the field, and the message stays while the copy
   shows.
6. **The tools are just below the field**: an element with the tools of
   the game has the attribute `data-phone="tools"`.

The common test checks the parts that need no browser: no key in the
markup of the page, no point from the rectangle of the canvas, no canvas
over the field, no text that names a direction, a text of `beneath` or
`above` only with `view.upright`, and the option `message` for a page
with a message. [`phone.js`](phone.js) checks the pages in a browser.
Look at its picture of your game before you make a pull request.

## On a phone

The world of a game is a box of 16 by 9, and a phone in portrait is 9 by
16. So on a phone in portrait (a screen of 700 pixels wide or less,
taller than it is wide), [`scene.js`](priv/assets/scene.js) turns the
world by 90 degrees: the +x of the world is up on the screen.

- All the world shows, and no game changes. On a screen of 390 by 844
  pixels, one unit of the world is 4.3 pixels (2.4 with no turn), and
  the animals are 1.25 times larger.
- The height of the field has a limit (`100svh`): the field, its bar of
  readings, its keys and the tools of the page are on the screen at one
  time. With the bars of a browser (a screen of 390 by 664 pixels), one
  unit is 3.8 pixels.
- The turn is in the scene only: the transform of the canvas, and
  `scene.toWorld(event)` (its inverse). The labels of the zones, the
  numbers on the boids, the stones and the shadows are upright. The
  server and the modules of the games do not know the turn.
- The readings are in a bar at the top of the field.
- The message of the game shows in a band below the readings: for some
  seconds when the message changes, and at the end of a level or of the
  game until the person presses the button. A number that changes (a
  clock) is not a new message. A touch on the band removes it.
- The scene makes the keys from the option `keys`. The arrows are
  directions of the screen: the scene changes them to directions of the
  world before it sends them. The keys are on the field at the bottom
  corners, and the field shows through them. On a screen that has room
  for the field at its full width and a bar, the keys are in a bar below
  the canvas.
- On a phone in landscape (a screen of 500 pixels high or less), there
  is no turn: the field fills the height, with the keys at its two
  sides. The tools of a page are lower in the page.

A page tells `Boids.scene` what it needs:

| Option or attribute | What |
|---|---|
| `keys: {into, pad, actions, mirror}` | The keys of the game. `into` is the element of the page that gets the keys on a large screen. `pad: true` gives four arrows. An action is `{label, key, codes}` (a key that the person holds) or `{label, send, codes}` (a message at each press); `side: "left"` puts it at the left corner. `mirror` is a list of buttons of the page: while a button shows in the page, a copy of it shows on the field. An entry can be `{button, when, end}`: `when` is a function that tells when the copy shows, and `end: false` is for a button that is not for the end of a level. |
| `message: element` | The element with the message of the game, or a list of elements (the first one that shows and has a text). `{from, stay}` has a function `stay` that tells when the message stays: for a game with no copy of a button on the field. |
| `data-phone="tools"` | An element of the page (the tools of a game) that is just below the field on a phone. `data-phone="open"` on an element between it and the column of the page lets it go there. |
| `scene.toWorld(event)` | The point of the world under a click or a touch. |
| `scene.direction("left")` | The direction of the world for a direction of the screen. |
| `beneath`, `above` | Drawings of the page under and over the boids, in pixels of the world. Their last argument is the view: `view.upright(x, y, draw)` draws at a point with no turn. |
| `turn: "down"`, `turn: false` | The +x of the world is down on the screen, or no turn. |
| `crop: {shape, follow}` | No turn: the field shows all the height of the world and a part of its width, and follows the boids of these kinds. |

- Hive Guard uses `turn: "down"`: the hive is at the bottom, near the
  tools, and the beetles come down to it.
- The home page uses `crop`: its world is 160 by 60, and turned it is
  taller than the screen. The flock is a picture and not a game, so a
  part of it that follows the hawk is sufficient.
- The playground uses `turn: false`: a definition has coordinates, and
  its x must go to the right. A visitor can give a tall box.

### The check of each page on a phone

[`phone.js`](phone.js) opens each page in Chromium at 390 by 844 pixels,
with touch, and takes a picture of each page. It fails when:

- a page has an error, or a sideways scroll;
- a field does not get the moments of its scene;
- a field, its bar of readings, its keys or the tools of its page are
  not on the screen at one time;
- a game does not show all its world, turned, with 3.5 pixels or more
  for one unit;
- a point of the screen and a point of the world do not agree, for a
  boid;
- an arrow does not move the animal the way of the arrow on the screen
  (Quiet Herd and Night Fold);
- a tap does not give the point of the world under the finger (Hive
  Guard and Firefly Field).

A page that did not load gets one more try. An error of a font of
another host is not an error of the site.

```sh
cd examples
npm install
npx playwright install chromium
mix run --no-halt &
npm run phone -- http://localhost:4000 phone
```

The pictures are in `phone/`. CI runs the check in the job "Examples",
at each push and for each pull request, and keeps the pictures of the
pages as the artifact `phone-pictures` of the run: look at them before
a deploy. The workflow "Deploy the site" starts only when CI is good on
`main`.

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
  in their folders.
- The game is the example of the library for a boid with a module of
  its own: see [`rock_patrol.ex`](rock_patrol/rock_patrol.ex).
- Long Flight is the example for rules as data:
  [`long_flight.ex`](long_flight/long_flight.ex). The deck of the person
  is the list of the rules of each bird, and the order of the list is
  the priority of the rules (`combine => priority`). A card adds a
  rule, changes a weight, makes a bird change its rules when it sees a
  hawk, or gives each bird a relation to an elder. A hawk sends a
  message to the bird that it catches, and a bird that is safe or lost
  stops. One process, the director, has the land, the deck and the
  counts of a run.
- Flock Lab waits for a program of the page (the callback `waits/0`):
  [`flock_lab.ex`](flock_lab/flock_lab.ex). A block of the kid is one
  rule from a fixed list, and the server checks each block. The levels
  have stars for the goal, the time and the number of blocks.
- Quiet Herd is the example for a state of each boid:
  [`quiet_herd.ex`](quiet_herd/quiet_herd.ex). The fear of a deer is its
  state, and changes its rules. The data of each boid tells its
  neighbors how fast the fox moves and how afraid a deer is, so fear
  goes from deer to deer with no message.
- Living Land is the example for processes that start and stop all the
  time: [`living_land.ex`](living_land/living_land.ex). The genes of an
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
