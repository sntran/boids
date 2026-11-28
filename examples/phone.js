// The check of the site on a phone: each page at 390 x 844 (a phone in
// portrait), with touch, in Chromium.
//
//     node phone.js [ADDRESS] [DIRECTORY]
//
// ADDRESS is the address of the site (http://localhost:4000 by default),
// and DIRECTORY gets a picture of each page (phone/ by default). The pages
// are the home page, the playground, the list of the showcases, and each
// game in the list. The check fails when:
//
// - a page has an error, or a sideways scroll;
// - a field does not get the moments of its scene;
// - a field, its bar of readings, its keys or the tools of its page are
//   not on the screen at one time;
// - a game does not show all its world, turned, with 3.5 pixels or more
//   for one unit (a field of 16 by 9 on all the width has 2.4);
// - a point of the screen and a point of the world do not agree, for a
//   boid (`scene.toWorld`);
// - an arrow of the keys does not move the animal the way of the arrow
//   on the screen (Quiet Herd and Night Fold);
// - a tap does not give the point of the world under the finger (Hive
//   Guard and Firefly Field).
//
// A page that did not load gets one more try: that is not an error of the
// site. The exit status is 1 when a check fails.
"use strict";
const fs = require("fs");
const path = require("path");
const { chromium } = require("playwright");

const base = (process.argv[2] || "http://localhost:4000").replace(/\/$/, "");
const out = process.argv[3] || "phone";
const phone = { viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, isMobile: true, hasTouch: true };
// The pixels of the screen for one unit of the world, at least, in a game.
const nearer = 3.5;
// The pages at one time. The site has a limit of the scenes at one time.
const together = 3;
// The direction of the world for each arrow of the screen, by the turn.
const arrows = {
  "1": { up: "right", right: "down", left: "up", down: "left" },
  "-1": { up: "left", left: "down", down: "right", right: "up" }
};

const wait = (ms) => new Promise((done) => setTimeout(done, ms));

// Wait until the site answers: a server that starts can need some time.
async function ready() {
  for (let i = 0; i < 90; i++) {
    try {
      const response = await fetch(base + "/");
      if (response.ok) { return; }
    } catch (e) {
      // No answer yet.
    }
    await wait(2000);
  }
  throw new Error(`no answer from ${base} in 3 minutes`);
}

// The facts of the page that the checks need.
function facts() {
  const field = document.querySelector(".field");
  const scene = window.Boids.scenes[0];
  const box = field.getBoundingClientRect();
  const bottom = (element) => element.getBoundingClientRect().bottom;
  const shown = (element) => !element.hidden && element.offsetHeight > 0;
  const tools = Array.prototype.filter.call(document.querySelectorAll('[data-phone="tools"]'), shown);
  const keys = Array.prototype.filter.call(field.querySelectorAll(".thumbs button"), shown);
  let far = 0;
  // Each boid: the point of the world under its point of the screen.
  scene.where().forEach((boid) => {
    const back = scene.toWorld({ clientX: boid.left, clientY: boid.top });
    far = Math.max(far, Math.abs(back[0] - boid.x), Math.abs(back[1] - boid.y));
  });
  return {
    height: window.innerHeight,
    sideways: document.documentElement.scrollWidth > window.innerWidth,
    view: scene.view(),
    boids: scene.where().length,
    far: far,
    lowest: Math.max(bottom(field), ...tools.map(bottom)),
    keys: keys.length,
    outside: keys.filter((key) => {
      const r = key.getBoundingClientRect();
      return r.left < box.left - 1 || r.right > box.right + 1 || r.top < box.top - 1 || r.bottom > box.bottom + 1;
    }).length
  };
}

// A finger that stays on an element for some time.
async function hold(page, cdp, selector, ms) {
  const b = await page.locator(selector).boundingBox();
  await cdp.send("Input.dispatchTouchEvent", { type: "touchStart", touchPoints: [{ x: b.x + b.width / 2, y: b.y + b.height / 2 }] });
  await wait(ms);
  await cdp.send("Input.dispatchTouchEvent", { type: "touchEnd", touchPoints: [] });
}

const where = (page, kind) => page.evaluate((name) => window.Boids.scenes[0].where(name), kind);

// Each arrow moves the animal of the person the way of the arrow on the
// screen, and the server gets the direction of the world.
function moves(kind) {
  return async (page, sent, fails, turn) => {
    const cdp = await page.context().newCDPSession(page);
    for (const key of ["up", "right", "left", "down"]) {
      const a = (await where(page, kind))[0];
      const count = sent.length;
      await hold(page, cdp, `.field .pad [data-key="${key}"]`, 1000);
      await wait(150);
      const b = (await where(page, kind))[0];
      const dx = b.left - a.left, dy = b.top - a.top;
      const good = { up: dy < -5 && -dy > 2 * Math.abs(dx), down: dy > 5 && dy > 2 * Math.abs(dx), left: dx < -5 && -dx > 2 * Math.abs(dy), right: dx > 5 && dx > 2 * Math.abs(dy) }[key];
      if (!good) { fails.push(`the arrow ${key} moves the ${kind} ${dx.toFixed(0)} px to the right and ${dy.toFixed(0)} px down`); }
      const want = `{"keys":["${arrows[String(turn)][key]}"]}`;
      if (!sent.slice(count).includes(want)) { fails.push(`the arrow ${key} sends ${sent.slice(count)[0]}, not ${want}`); }
    }
  };
}

// A tap on the field sends the point of the world under the finger. The
// point comes from the geometry of the turned world, not from the scene.
function taps(key, box, kind) {
  return async (page, sent, fails, turn) => {
    const canvas = await page.locator(".field canvas").boundingBox();
    for (const [fx, fy] of [[0.3, 0.55], [0.72, 0.3]]) {
      const point = { x: canvas.x + canvas.width * fx, y: canvas.y + canvas.height * fy };
      const want = turn === 1 ? [(1 - fy) * box[0], (1 - fx) * box[1]] : [fy * box[0], fx * box[1]];
      const count = sent.length;
      await page.touchscreen.tap(point.x, point.y);
      await wait(900);
      const frame = sent.slice(count).find((text) => text.includes(`"${key}"`));
      const got = frame ? JSON.parse(frame)[key] : null;
      if (!got || Math.abs(got[0] - want[0]) > 0.4 || Math.abs(got[1] - want[1]) > 0.4) {
        fails.push(`a tap at ${fx}, ${fy} of the field sends ${frame}, not the point ${want.map((v) => v.toFixed(1))}`);
      }
      // The new boid shows under the finger.
      if (kind) {
        const best = (await where(page, kind)).map((b) => Math.hypot(b.left - point.x, b.top - point.y)).sort((a, b) => a - b)[0];
        if (!(best < 12)) { fails.push(`after a tap, the nearest of the ${kind} is ${best === undefined ? "not there" : best.toFixed(0) + " px from the finger"}`); }
      }
    }
  };
}

const plays = {
  "/showcases/quiet-herd": moves("fox"),
  "/showcases/night-fold": moves("dog"),
  "/showcases/hive-guard": taps("place", [160, 90], "scouts"),
  "/showcases/firefly-field": taps("lantern", [160, 90])
};

async function check(browser, route, name) {
  const context = await browser.newContext(phone);
  const page = await context.newPage();
  const errors = [];
  const sent = [];
  const fails = [];
  let note = "";
  let loaded = true;
  page.on("pageerror", (error) => errors.push(String(error)));
  // An error of the console that comes from the site, not from a font of another host.
  page.on("console", (message) => {
    if (message.type() === "error" && String(message.location().url || base).startsWith(base)) { errors.push(message.text()); }
  });
  page.on("websocket", (socket) => socket.on("framesent", (frame) => sent.push(String(frame.payload))));

  try {
    const response = await page.goto(base + route, { waitUntil: "domcontentloaded", timeout: 30000 });
    if (!response || response.status() !== 200) { loaded = false; fails.push(`status ${response && response.status()}`); }
    if (loaded && await page.evaluate(() => !!document.querySelector(".field canvas"))) {
      try {
        await page.waitForFunction(() => (document.getElementById("source") || {}).textContent === "Live", null, { timeout: 30000 });
      } catch (e) {
        loaded = false;
        fails.push("the field is not live");
      }
    }
  } catch (error) {
    loaded = false;
    fails.push(String(error.message || error).split("\n")[0]);
  }

  if (loaded && await page.evaluate(() => !!document.querySelector(".field canvas"))) {
    await page.evaluate(() => document.querySelector(".field").scrollIntoView({ block: "start" }));
    await wait(2000);
    const f = await page.evaluate(facts);
    const game = route.startsWith("/showcases/");
    note = `turn ${f.view.turn}${f.view.crop ? ", a part of the world" : ""}, ${f.view.unit.toFixed(2)} px for one unit, ${f.keys} keys`;
    if (!f.view.phone) { fails.push("no phone layout"); }
    if (f.sideways) { fails.push("sideways scroll"); }
    if (f.lowest > f.height + 1) { fails.push(`the field and its tools end at ${Math.round(f.lowest)} px, below the screen`); }
    if (f.outside > 0) { fails.push(`${f.outside} keys are not on the field`); }
    if (game && f.view.turn === 0) { fails.push("the world is not turned"); }
    if (game && f.view.unit < nearer) { fails.push(`${f.view.unit.toFixed(2)} px for one unit of the world`); }
    if (f.boids === 0) { fails.push("no boid on the field"); }
    if (f.far > 0.25) { fails.push(`a point of the screen is ${f.far.toFixed(2)} units from its point of the world`); }
    await page.screenshot({ path: path.join(out, `${name}.png`) });
    if (plays[route]) { await plays[route](page, sent, fails, f.view.turn); }
  } else if (loaded) {
    if (await page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth)) { fails.push("sideways scroll"); }
    await page.screenshot({ path: path.join(out, `${name}.png`) });
  }

  if (errors.length > 0) { fails.push(`errors: ${errors.slice(0, 2).join(" | ")}`); }
  await context.close();
  return { fails, note, loaded };
}

(async () => {
  const start = Date.now();
  fs.mkdirSync(out, { recursive: true });
  await ready();
  const browser = await chromium.launch(process.env.CHROMIUM ? { executablePath: process.env.CHROMIUM } : {});
  // The games: the links of the list of the showcases.
  const list = await browser.newPage();
  await list.goto(base + "/showcases", { waitUntil: "domcontentloaded" });
  const games = await list.evaluate(() =>
    Array.from(new Set(Array.prototype.map.call(document.querySelectorAll('a[href^="/showcases/"]'), (a) => a.getAttribute("href")))));
  await list.close();

  const routes = [["/", "home"], ["/playground", "playground"], ["/showcases", "showcases"]]
    .concat(games.map((route) => [route, route.replace("/showcases/", "")]));
  const results = [];
  let next = 0;
  await Promise.all(Array.from({ length: together }, async () => {
    while (next < routes.length) {
      const index = next++;
      const [route, name] = routes[index];
      let result;
      try {
        result = await check(browser, route, name);
        // One more try for a page that did not load.
        if (!result.loaded) { result = await check(browser, route, name); result.note += " (second try)"; }
      } catch (error) {
        result = { note: "", fails: [String(error.message || error).split("\n")[0]] };
      }
      results[index] = result;
    }
  }));
  await browser.close();

  let failed = 0;
  routes.forEach(([route], index) => {
    const result = results[index];
    const ok = result.fails.length === 0;
    if (!ok) { failed++; }
    console.log(`${ok ? "ok  " : "FAIL"} ${route} ${result.note}${ok ? "" : " - " + result.fails.join("; ")}`);
  });
  console.log(`${routes.length - failed} of ${routes.length} pages are good on a phone, in ${Math.round((Date.now() - start) / 1000)} s. The pictures are in ${out}/.`);
  process.exit(failed === 0 ? 0 : 1);
})().catch((error) => { console.error(error); process.exit(1); });
