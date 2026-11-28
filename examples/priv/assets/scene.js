// A scene of the site of boids: a WebSocket to a world with boids
// on the server, and a canvas that draws each moment of these boids.
//
//   var scene = Boids.scene({name: "game", canvas: element, readings: element, source: element});
//   scene.send({keys: ["left"]});
//
// A page that reads a point of the field (a click, a touch) uses
// `scene.toWorld(event)`: the point of the world under the event. The
// options `beneath` and `above` draw things of the page under and over
// the boids, in the pixels of the world (1600 for its width). Their last
// argument is the view: `view.turn` (see below) and `view.upright(x, y,
// draw)`, which draws at a point with no turn (for a text, or a thing
// with a top and a bottom).
//
// On a phone, the world of a game (a box of 16 by 9) does not have the
// shape of the screen (9 by 16). So on a phone in portrait (a screen of
// 700 px wide or less, taller than it is wide), the scene turns the
// world by 90 degrees: the +x of the world is up on the screen. All the
// world shows, and no game changes.
//
// - `turn: "down"`: the +x of the world is down on the screen.
//   `turn: false`: no turn (the playground: its definitions have
//   coordinates).
// - `crop: {shape: 4 / 3, follow: ["hawk"]}`: no turn. The field shows
//   all the height of the world and a part of its width, and follows the
//   boids of these kinds (the home page: its flock is only a picture).
// - `keys`: the keys of a game. The scene makes them: in the element
//   `into` of the page on a large screen, and on the field at the bottom
//   corners on a phone.
//       keys: {into: element, pad: true, actions: [...], mirror: [...]}
//   `pad: true` gives four arrows. They are directions of the screen: the
//   scene changes them to directions of the world before it sends them
//   (`{keys: ["left", "run"]}`). An action is `{label, key, codes}` (a
//   key that the person holds) or `{label, send, codes}` (a message at
//   each press). `codes` are the codes of the keys of a keyboard. `side:
//   "left"` puts an action at the left corner. `mirror` is a list of
//   buttons of the page: while a button shows in the page, a copy of it
//   shows on the field of a phone.
// - `scene.direction("left")` gives the direction of the world for a
//   direction of the screen.
// - The readings are in a bar at the top of the field.
// - `message`: the element of the page with the message of the game (or
//   a list of elements: the first one that shows and has a text). On a
//   phone the page is below the screen, so the scene shows the text in a
//   band on the field, below the readings: for some seconds when the
//   message changes, and at the end of a level or of the game until the
//   person presses the button. The end is the time while a copy of a
//   button of `mirror` shows (`{button, end: false}` for a button that is
//   not for the end), or while the function `stay` gives true:
//       message: {from: element, stay: function () { return over; }}
//
// On a phone in landscape (a screen of 500 px high or less), the field
// fills the height of the screen, with the keys at its two sides.
(function () {
  "use strict";

  function media(query) { return window.matchMedia ? window.matchMedia(query) : { matches: false }; }
  // A phone in portrait, and a phone in landscape.
  var portrait = media("(max-width: 700px) and (orientation: portrait)");
  var landscape = media("(max-height: 500px) and (orientation: landscape)");
  // On a phone in portrait, the animals and the labels are this many times
  // larger.
  var grow = 1.25;
  // The direction of the world for a direction of the screen, when the +x
  // of the world is up (1) or down (-1) on the screen.
  var turns = {
    "1": { up: "right", right: "down", down: "left", left: "up" },
    "-1": { up: "left", left: "down", down: "right", right: "up" }
  };

  function scene(options) {
    var canvas = options.canvas;
    var ctx = canvas.getContext("2d");
    var field = canvas.closest(".field") || canvas.parentNode;
    // The world in pixels: 1600 for its width. All the drawings use these
    // pixels, and the view puts them on the canvas.
    var W = 1600, H = 900;
    // The view: 0 (the world as it is), 1 (its +x is up on the screen) or
    // -1 (its +x is down).
    var turn = 0;
    var crop = null;
    var cam = { x: 0, cx: null, at: 0 };   // the left side of a crop, in pixels of the world
    var boost = 1;
    var shown = [];                        // the boids of the last frame
    var onField = false;                   // the keys and the readings are on the field
    var run = null;        // the box, the kinds and the rocks
    var before = {};       // the boids of the moment before the last moment, by their number
    var last = null;       // the last moment
    var links = [];        // the relations, as pairs of numbers
    var extra = {};        // more of the last moment (the game)
    var lastAt = 0;
    var period = 50;
    var paused = false;
    var showLinks = true;
    var socket = null;
    var tries = 0;

    function note(text) { if (options.source) { options.source.textContent = text; } }

    function colors() {
      var style = getComputedStyle(document.documentElement);
      var read = function (name) { return style.getPropertyValue(name).trim(); };
      var c = {};
      ["rock", "warm", "cool", "panel", "field", "wool", "fur", "gold", "leaf", "plum", "edge", "shade", "grass", "water", "sand", "floor", "night"]
        .forEach(function (name) { c[name] = read("--" + name); });
      c.ink = read("--boid");
      return c;
    }

    function start(header) {
      run = header;
      period = header.tick;
      last = null;
      links = [];
      W = 1600;
      H = Math.round(1600 * run.box[1] / run.box[0]);
      cam.cx = null;
      layout();
      readingsHost().textContent = "";
      note("Live");
      if (options.onStart) { options.onStart(header); }
    }

    function byNumber(moment) {
      var map = {};
      for (var i = 0; i < moment.b.length; i += 6) { map[moment.b[i]] = [moment.b[i + 1], moment.b[i + 2], moment.b[i + 3]]; }
      return map;
    }

    // A reading of the server: a label and a value below the canvas.
    function reading(label, value) {
      var id = "reading-" + label.replace(/\W+/g, "-");
      var element = document.getElementById(id);
      if (!element) {
        element = document.createElement("div");
        element.className = "reading";
        element.id = id;
        element.appendChild(document.createElement("span")).textContent = label;
        element.appendChild(document.createElement("b"));
        readingsHost().appendChild(element);
      }
      element.lastChild.textContent = value;
    }

    // --- The view ------------------------------------------------------

    // The bar of the field for the readings, on a phone.
    var hud = document.createElement("div");
    hud.className = "hud";
    field.insertBefore(hud, field.firstChild);
    var spare = document.createElement("div");
    function readingsHost() { return onField ? hud : (options.readings || spare); }

    // Draw at a point of the world with no turn: a text, or a thing with a
    // top and a bottom.
    function upright(x, y, draw) {
      ctx.save();
      ctx.translate(x, y);
      if (turn) { ctx.rotate(turn * Math.PI / 2); }
      draw();
      ctx.restore();
    }

    // A distance on the screen (to the right, down), in the world.
    function fromScreen(dx, dy) { return turn === 1 ? [-dy, dx] : (turn === -1 ? [dy, -dx] : [dx, dy]); }

    // The direction of the world for a direction of the screen.
    function direction(name) { return turn ? turns[turn][name] || name : name; }

    // The size of the canvas for the view.
    function size() {
      var w = turn ? H : (crop ? Math.round(H * crop.shape) : W);
      var h = turn ? W : H;
      if (canvas.width !== w) { canvas.width = w; }
      if (canvas.height !== h) { canvas.height = h; }
      fit();
    }

    // The canvas and the things of the field that are near it are on the
    // screen at one time: the bar of the readings, and the tools of the
    // page that are below the field (`data-phone="tools"`).
    var below = 0;
    // The height of the screen with the bars of the browser (100svh), in pixels.
    var probe = document.createElement("div");
    probe.style.cssText = "position:fixed;left:0;top:0;width:0;height:100svh;visibility:hidden;pointer-events:none";
    field.appendChild(probe);
    function fit() {
      if (!onField) { canvas.style.maxHeight = ""; field.classList.remove("bar"); return; }
      var tools = 0;
      Array.prototype.forEach.call(document.querySelectorAll('[data-phone="tools"]'), function (element) {
        if (element.offsetHeight > 0) { tools += element.offsetHeight + 10; }
      });
      // The tools can hide for a time: the field keeps its size. In
      // landscape, the tools are lower in the page.
      below = portrait.matches ? Math.max(below, tools) : 0;
      // The keys are in a bar below the canvas when the screen has room for
      // the canvas at its full width and the bar. If not, they are on the
      // canvas: a bar then makes the field small. A field with only copies
      // of buttons of the page has no bar: a copy shows only for a time.
      var room = probe.offsetHeight - hud.offsetHeight - below - 4;
      var full = field.clientWidth * canvas.height / canvas.width;
      var inBar = portrait.matches && all.length > 0 && room - thumbs.offsetHeight >= full;
      field.classList.toggle("bar", inBar);
      var most = "calc(100svh - " + (hud.offsetHeight + below + (inBar ? thumbs.offsetHeight : 0) + 4) + "px)";
      if (canvas.style.maxHeight !== most) { canvas.style.maxHeight = most; }
    }

    function layout() {
      var tall = portrait.matches, low = landscape.matches;
      crop = tall && options.crop ? options.crop : null;
      turn = tall && !crop && options.turn !== false ? (options.turn === "down" ? -1 : 1) : 0;
      boost = tall ? grow : 1;
      var before = onField;
      onField = tall || low;
      field.classList.toggle("phone", onField);
      field.classList.toggle("turned", turn !== 0);
      field.classList.toggle("wide", low);
      document.documentElement.classList.toggle("boids-phone", onField);
      if (before !== onField) {
        // The readings go to their new place.
        var from = before ? hud : (options.readings || spare);
        while (from.firstChild) { readingsHost().appendChild(from.firstChild); }
      }
      placeKeys();
      size();
      if (Object.keys(down).length > 0) { sendKeys(); }
    }

    // The point of a crop to follow, in pixels of the world, or null.
    function focus(list) {
      var sum = 0, count = 0;
      list.forEach(function (boid) { if ((crop.follow || []).indexOf(boid.kind.name) >= 0) { sum += boid.x; count++; } });
      return count > 0 ? sum / count : null;
    }

    // The left side of a crop in this frame.
    function camera(list, now) {
      if (!crop) { cam.x = 0; return; }
      var width = canvas.width;
      var target = focus(list);
      if (cam.cx === null) { cam.cx = target === null ? W / 2 : target; }
      if (target !== null) {
        // A target that went across a side of the world: the view jumps.
        if (Math.abs(target - cam.cx) > W / 2) { cam.cx = target; }
        else { cam.cx += (target - cam.cx) * Math.min(1, Math.max(0, now - cam.at) / 350); }
      }
      cam.cx = width >= W ? W / 2 : Math.max(width / 2, Math.min(W - width / 2, cam.cx));
      cam.x = cam.cx - width / 2;
      cam.at = now;
    }

    // The point of the canvas for a point of the world, both in pixels.
    function toCanvas(x, y) { return turn === 1 ? [y, W - x] : (turn === -1 ? [H - y, x] : [x - cam.x, y]); }

    // --- The keys of a game --------------------------------------------

    var down = {};      // the keys that are down: "pad-up" for an arrow, or the name of a key
    var buttons = {};
    var all = [];       // the keys in the order of the page
    var corners = { left: [], right: [] };
    var mirrors = [];
    var thumbs = document.createElement("div");
    thumbs.className = "thumbs";
    var corner = {};
    ["left", "right"].forEach(function (side) {
      corner[side] = thumbs.appendChild(document.createElement("div"));
      corner[side].className = "thumb " + side;
    });
    field.appendChild(thumbs);

    function sendKeys() {
      send({ keys: Object.keys(down).map(function (id) { return id.indexOf("pad-") === 0 ? direction(id.slice(4)) : id; }) });
    }

    function setKey(id, on) {
      if (!id || !!down[id] === on) { return; }
      if (on) { down[id] = true; } else { delete down[id]; }
      if (buttons[id]) { buttons[id].classList.toggle("down", on); }
      sendKeys();
    }

    function button(label, className) {
      var element = document.createElement("button");
      element.type = "button";
      element.className = className;
      element.textContent = label;
      return element;
    }

    // A key that the person holds.
    function hold(element, id) {
      buttons[id] = element;
      element.addEventListener("pointerdown", function (event) { event.preventDefault(); setKey(id, true); });
      ["pointerup", "pointerleave", "pointercancel"].forEach(function (type) {
        element.addEventListener(type, function () { setKey(id, false); });
      });
      // A long touch opens no menu.
      element.addEventListener("contextmenu", function (event) { event.preventDefault(); });
    }

    function makeKeys(spec) {
      var codes = {};
      if (spec.pad) {
        var pad = document.createElement("div");
        pad.className = "pad";
        [["up", "Up", ["ArrowUp", "KeyW"]], ["left", "Left", ["ArrowLeft", "KeyA"]],
         ["down", "Down", ["ArrowDown", "KeyS"]], ["right", "Right", ["ArrowRight", "KeyD"]]].forEach(function (one) {
          var element = pad.appendChild(button(one[1], ""));
          element.setAttribute("data-key", one[0]);
          element.setAttribute("aria-label", one[1]);
          hold(element, "pad-" + one[0]);
          one[2].forEach(function (code) { codes[code] = { hold: "pad-" + one[0] }; });
        });
        all.push(pad);
        corners.left.push(pad);
      }
      (spec.actions || []).forEach(function (action) {
        var element = button(action.label, "key");
        if (action.key) {
          element.setAttribute("data-key", action.key);
          hold(element, action.key);
        } else {
          element.addEventListener("click", function () { send(action.send); });
        }
        (action.codes || []).forEach(function (code) { codes[code] = action.key ? { hold: action.key } : { send: action.send }; });
        all.push(element);
        corners[action.side === "left" ? "left" : "right"].push(element);
      });
      // A copy of a button of the page: the button, or `{button, when}`
      // with a function that tells when the copy shows.
      (spec.mirror || []).forEach(function (entry) {
        var plain = entry instanceof Element;
        var original = plain ? entry : entry.button;
        var copy = button("", "key mirror");
        copy.hidden = true;
        copy.addEventListener("click", function () { original.click(); });
        mirrors.push([original, copy, plain ? null : entry.when, plain || entry.end !== false]);
      });

      window.addEventListener("keydown", function (event) {
        var code = codes[event.code];
        if (!code || event.target.closest("textarea, input, select")) { return; }
        event.preventDefault();
        if (code.hold) { setKey(code.hold, true); } else if (!event.repeat) { send(code.send); }
      });
      window.addEventListener("keyup", function (event) { if (codes[event.code]) { setKey(codes[event.code].hold, false); } });
      // A window that loses the focus gets no keyup: the keys go up.
      window.addEventListener("blur", function () { Object.keys(down).forEach(function (id) { setKey(id, false); }); });
      // The server gets the keys again each second, while a key is down.
      setInterval(function () { if (Object.keys(down).length > 0) { sendKeys(); } }, 1000);
    }

    // The keys are on the field on a phone, and in the element `into` of
    // the page on a large screen, before its text.
    function placeKeys() {
      var into = options.keys && options.keys.into;
      if (onField) {
        ["left", "right"].forEach(function (side) { corners[side].forEach(function (element) { corner[side].appendChild(element); }); });
        mirrors.forEach(function (pair) { corner.right.appendChild(pair[1]); });
      } else {
        mirrors.forEach(function (pair) { if (pair[1].parentNode) { pair[1].parentNode.removeChild(pair[1]); } });
        if (into) { all.slice().reverse().forEach(function (element) { into.insertBefore(element, into.firstChild); }); }
      }
    }

    // True while the element shows in the page: no part of the page that
    // holds it is hidden.
    function inPage(element) {
      for (var e = element; e && e !== document.body; e = e.parentNode) { if (e.hidden) { return false; } }
      return true;
    }

    // --- The message of the game ---------------------------------------

    var band = document.createElement("div");
    band.className = "band";
    band.hidden = true;
    // The page has the message for a screen reader.
    band.setAttribute("aria-hidden", "true");
    field.insertBefore(band, canvas);
    var said = { shape: null, until: 0, closed: false };
    // A touch on the band removes it until the next message.
    band.addEventListener("click", function () { said.closed = true; band.hidden = true; });

    function showMessage() {
      var spec = options.message;
      if (!spec) { return; }
      var plain = spec instanceof Element || Array.isArray(spec);
      var text = "";
      [].concat(plain ? spec : spec.from).some(function (element) {
        // The parts of the element, with a space between them.
        text = !inPage(element) ? "" : Array.prototype.map.call(element.childNodes, function (node) {
          return node.textContent.replace(/\s+/g, " ").trim();
        }).filter(function (part) { return part !== ""; }).join(" ");
        return text !== "";
      });
      // A number that changes (a clock) is not a new message.
      var shape = text.replace(/\d+([.,]\d+)?/g, "0");
      var now = performance.now();
      if (shape !== said.shape) {
        said.shape = shape;
        said.closed = false;
        said.until = now + Math.min(12000, 4000 + 60 * text.length);
      }
      var end = !plain && spec.stay ? !!spec.stay() : mirrors.some(function (pair) { return pair[3] && !pair[1].hidden; });
      band.hidden = text === "" || said.closed || !(end || now < said.until);
      band.classList.toggle("end", end);
      if (!band.hidden && band.textContent !== text) { band.textContent = text; }
      band.style.top = hud.offsetHeight + "px";
    }

    // The copies follow the buttons of the page, the band follows the
    // message, and the field follows the size of its bars.
    setInterval(function () {
      if (!onField) { band.hidden = true; return; }
      mirrors.forEach(function (pair) {
        pair[1].hidden = !inPage(pair[0]) || (!!pair[2] && !pair[2]());
        pair[1].disabled = pair[0].disabled;
        if (pair[1].textContent !== pair[0].textContent) { pair[1].textContent = pair[0].textContent; }
        pair[1].classList.toggle("main", pair[0].classList.contains("main"));
      });
      showMessage();
      fit();
    }, 250);

    if (options.keys) { makeKeys(options.keys); }
    [portrait, landscape].forEach(function (query) {
      if (query.addEventListener) { query.addEventListener("change", layout); } else if (query.addListener) { query.addListener(layout); }
    });
    window.addEventListener("resize", fit);
    layout();

    function take(moment) {
      before = last ? byNumber(last) : {};
      last = moment;
      lastAt = performance.now();
      if (moment.l) { links = moment.l; }
      if (moment.x) { extra = moment.x; }
      // A scene can change its rocks and its zones while it runs.
      if (moment.h && run) {
        if (moment.h.rocks) { run.rocks = moment.h.rocks; }
        if (moment.h.zones) { run.zones = moment.h.zones; }
      }
      if (moment.x && options.onMore) { options.onMore(moment.x); }
      (moment.r || []).forEach(function (pair) { reading(pair[0], pair[1]); });
    }

    // The position between two moments. A boid that went across a side of
    // the box is at its new position.
    function between(a, b, size, part) { return Math.abs(b - a) > size / 2 ? b : a + (b - a) * part; }

    function sweep(a, b, part) {
      var d = b - a;
      if (d > Math.PI) { d -= 2 * Math.PI; } else if (d < -Math.PI) { d += 2 * Math.PI; }
      return a + d * part;
    }

    // A rock has a shape of its own, from its number.
    function rock(number, radius, time) {
      var spin = ((number % 7) - 3) * 0.00012 * time;
      ctx.beginPath();
      for (var k = 0; k < 9; k++) {
        var r = radius * (0.78 + 0.3 * (((number * (k + 3) * 2654435761) >>> 0) % 100) / 100);
        var a = spin + k * 2 * Math.PI / 9;
        ctx.lineTo(r * Math.cos(a), r * Math.sin(a));
      }
      ctx.closePath();
      ctx.fill();
    }

    function dart(size) {
      ctx.beginPath();
      ctx.moveTo(size, 0);
      ctx.lineTo(-size * 0.8, size * 0.6);
      ctx.lineTo(-size * 0.4, 0);
      ctx.lineTo(-size * 0.8, -size * 0.6);
      ctx.closePath();
      ctx.fill();
    }

    // --- The animals --------------------------------------------------
    //
    // Each shape is drawn from above, with the head to the right (+x):
    // the canvas is already turned to the direction of the boid. `s` is
    // the size of the kind in pixels (about half the length of the
    // body), `t` the time in milliseconds, `p` a phase of its own (from
    // the number of the boid), and `c` the colors of the theme.
    function ellipse(x, y, rx, ry, angle) {
      ctx.beginPath();
      ctx.ellipse(x, y, Math.max(rx, 0.1), Math.max(ry, 0.1), angle || 0, 0, 2 * Math.PI);
    }

    function fillEdge(fill, c, width) {
      ctx.fillStyle = fill;
      ctx.fill();
      ctx.lineWidth = width || 1.2;
      ctx.strokeStyle = c.edge;
      ctx.stroke();
    }

    function legs(s, count, span, length, swing, c) {
      ctx.strokeStyle = c.edge;
      ctx.lineWidth = Math.max(1, s * 0.07);
      ctx.beginPath();
      for (var k = 0; k < count; k++) {
        var x = -span / 2 + span * k / Math.max(count - 1, 1);
        var w = (k % 2 === 0 ? 1 : -1) * swing;
        ctx.moveTo(x, 0); ctx.lineTo(x + w, length);
        ctx.moveTo(x, 0); ctx.lineTo(x - w, -length);
      }
      ctx.stroke();
    }

    var sprites = {
      bird: function (s, t, p, fill, c) {
        var flap = 0.55 + 0.45 * Math.sin(t * 0.018 + p);
        ctx.fillStyle = fill;
        ctx.globalAlpha = 0.85;
        [-1, 1].forEach(function (side) {
          ctx.beginPath();
          ctx.moveTo(s * 0.25, 0);
          ctx.quadraticCurveTo(-s * 0.05, side * s * 1.1 * flap, -s * 0.45, side * s * 0.95 * flap);
          ctx.quadraticCurveTo(-s * 0.2, side * s * 0.25, -s * 0.15, 0);
          ctx.fill();
        });
        ctx.globalAlpha = 1;
        ellipse(0, 0, s * 0.62, s * 0.2);
        fillEdge(fill, c);
        ctx.beginPath();
        ctx.moveTo(-s * 0.5, 0); ctx.lineTo(-s * 0.95, s * 0.22); ctx.lineTo(-s * 0.85, 0); ctx.lineTo(-s * 0.95, -s * 0.22);
        ctx.closePath(); ctx.fillStyle = fill; ctx.fill();
        ctx.beginPath();
        ctx.moveTo(s * 0.6, -s * 0.07); ctx.lineTo(s * 0.85, 0); ctx.lineTo(s * 0.6, s * 0.07);
        ctx.fillStyle = c.gold; ctx.fill();
      },
      sheep: function (s, t, p, fill, c) {
        var bob = Math.sin(t * 0.006 + p) * s * 0.03;
        ctx.fillStyle = c.ink;
        ellipse(s * 0.62 + bob, 0, s * 0.24, s * 0.17); ctx.fill();
        ellipse(s * 0.55, -s * 0.2, s * 0.1, s * 0.05, -0.6); ctx.fill();
        ellipse(s * 0.55, s * 0.2, s * 0.1, s * 0.05, 0.6); ctx.fill();
        var puffs = [[0.35, 0, 0.3], [0.05, -0.3, 0.3], [0.05, 0.3, 0.3], [-0.3, -0.22, 0.3], [-0.3, 0.22, 0.3], [-0.5, 0, 0.28], [0, 0, 0.42]];
        puffs.forEach(function (q) { ellipse(q[0] * s, q[1] * s, q[2] * s, q[2] * s); fillEdge(fill === c.ink ? c.wool : fill, c, 1); });
        puffs.forEach(function (q) { ellipse(q[0] * s, q[1] * s, q[2] * s * 0.82, q[2] * s * 0.82); ctx.fillStyle = fill === c.ink ? c.wool : fill; ctx.fill(); });
      },
      dog: function (s, t, p, fill, c, wolf) {
        var wag = Math.sin(t * (wolf ? 0.008 : 0.03) + p) * 0.5;
        ctx.save(); ctx.translate(-s * 0.55, 0); ctx.rotate(wag);
        ellipse(-s * 0.3, 0, s * (wolf ? 0.38 : 0.3), s * (wolf ? 0.13 : 0.07));
        fillEdge(fill, c); ctx.restore();
        ctx.save(); ctx.translate(0, 0); legs(s, 2, s * 0.8, s * 0.32, Math.sin(t * 0.02 + p) * s * 0.12, c); ctx.restore();
        ellipse(0, 0, s * 0.62, s * 0.32); fillEdge(fill, c);
        ellipse(s * 0.66, 0, s * 0.27, s * 0.24); fillEdge(fill, c);
        ctx.beginPath();
        ctx.moveTo(s * 0.85, -s * 0.08); ctx.lineTo(s * 1.08, 0); ctx.lineTo(s * 0.85, s * 0.08); ctx.closePath();
        ctx.fillStyle = fill; ctx.fill();
        [-1, 1].forEach(function (side) {
          ctx.beginPath();
          if (wolf) { ctx.moveTo(s * 0.62, side * s * 0.12); ctx.lineTo(s * 0.5, side * s * 0.34); ctx.lineTo(s * 0.74, side * s * 0.2); }
          else { ellipse(s * 0.55, side * s * 0.24, s * 0.13, s * 0.07, side * 0.5); }
          ctx.fillStyle = c.edge; ctx.fill();
        });
      },
      wolf: function (s, t, p, fill, c) { sprites.dog(s, t, p, fill, c, true); },
      fish: function (s, t, p, fill, c, big) {
        var wig = Math.sin(t * 0.02 + p) * 0.35;
        ctx.save(); ctx.translate(-s * 0.55, 0); ctx.rotate(wig);
        ctx.beginPath(); ctx.moveTo(0, 0); ctx.lineTo(-s * 0.45, s * 0.32); ctx.lineTo(-s * 0.38, 0); ctx.lineTo(-s * 0.45, -s * 0.32); ctx.closePath();
        fillEdge(fill, c, 1); ctx.restore();
        ctx.beginPath();
        ctx.moveTo(s * 0.75, 0);
        ctx.bezierCurveTo(s * 0.45, s * (big ? 0.34 : 0.4), -s * 0.35, s * (big ? 0.3 : 0.32), -s * 0.6, 0);
        ctx.bezierCurveTo(-s * 0.35, -s * (big ? 0.3 : 0.32), s * 0.45, -s * (big ? 0.34 : 0.4), s * 0.75, 0);
        fillEdge(fill, c, 1);
        if (big) {
          [-1, 1].forEach(function (side) {
            ctx.beginPath(); ctx.moveTo(s * 0.15, side * s * 0.25); ctx.lineTo(-s * 0.15, side * s * 0.6); ctx.lineTo(-s * 0.1, side * s * 0.22); ctx.closePath();
            ctx.fillStyle = fill; ctx.fill();
          });
          ctx.strokeStyle = c.edge; ctx.lineWidth = 1; ctx.beginPath(); ctx.moveTo(s * 0.4, -s * 0.12); ctx.lineTo(s * 0.4, s * 0.12); ctx.stroke();
        }
        ellipse(s * 0.45, -s * 0.12, s * 0.06, s * 0.06); ctx.fillStyle = c.edge; ctx.fill();
      },
      shark: function (s, t, p, fill, c) { sprites.fish(s, t, p, fill, c, true); },
      deer: function (s, t, p, fill, c) {
        legs(s, 2, s * 0.8, s * 0.3, Math.sin(t * 0.015 + p) * s * 0.1, c);
        ellipse(-s * 0.62, 0, s * 0.12, s * 0.1); ctx.fillStyle = c.wool; ctx.fill();
        ellipse(0, 0, s * 0.62, s * 0.34); fillEdge(fill, c);
        ellipse(s * 0.72, 0, s * 0.24, s * 0.18); fillEdge(fill, c);
        [-1, 1].forEach(function (side) { ellipse(s * 0.62, side * s * 0.2, s * 0.12, s * 0.05, side * 0.8); ctx.fillStyle = fill; ctx.fill(); });
        ctx.fillStyle = c.wool; ctx.globalAlpha = 0.7;
        [[-0.2, -0.12], [0.1, 0.1], [-0.35, 0.08], [0.25, -0.1]].forEach(function (q) { ellipse(q[0] * s, q[1] * s, s * 0.05, s * 0.05); ctx.fill(); });
        ctx.globalAlpha = 1;
      },
      fox: function (s, t, p, fill, c) {
        var swish = Math.sin(t * 0.01 + p) * 0.35;
        ctx.save(); ctx.translate(-s * 0.5, 0); ctx.rotate(swish);
        ellipse(-s * 0.4, 0, s * 0.45, s * 0.2); fillEdge(fill, c);
        ellipse(-s * 0.75, 0, s * 0.13, s * 0.12); ctx.fillStyle = c.wool; ctx.fill(); ctx.restore();
        legs(s, 2, s * 0.6, s * 0.26, Math.sin(t * 0.03 + p) * s * 0.12, c);
        ellipse(0, 0, s * 0.52, s * 0.28); fillEdge(fill, c);
        ctx.beginPath(); ctx.moveTo(s * 0.35, -s * 0.24); ctx.lineTo(s * 0.95, 0); ctx.lineTo(s * 0.35, s * 0.24); ctx.closePath(); fillEdge(fill, c);
        [-1, 1].forEach(function (side) {
          ctx.beginPath(); ctx.moveTo(s * 0.5, side * s * 0.1); ctx.lineTo(s * 0.38, side * s * 0.32); ctx.lineTo(s * 0.62, side * s * 0.16); ctx.closePath();
          ctx.fillStyle = c.edge; ctx.fill();
        });
      },
      bee: function (s, t, p, fill, c) {
        var buzz = 0.6 + 0.4 * Math.abs(Math.sin(t * 0.06 + p));
        ctx.globalAlpha = 0.55; ctx.fillStyle = c.wool;
        [-1, 1].forEach(function (side) { ellipse(-s * 0.05, side * s * 0.42 * buzz, s * 0.32, s * 0.2 * buzz, side * 0.4); ctx.fill(); });
        ctx.globalAlpha = 1;
        ellipse(0, 0, s * 0.58, s * 0.34); fillEdge(fill === c.ink ? c.gold : fill, c);
        ctx.fillStyle = c.ink;
        [-0.25, 0.05].forEach(function (x) { ctx.fillRect(x * s, -s * 0.32, s * 0.12, s * 0.64); });
        ellipse(s * 0.58, 0, s * 0.16, s * 0.16); ctx.fill();
      },
      beetle: function (s, t, p, fill, c) {
        legs(s, 3, s * 0.7, s * 0.5, Math.sin(t * 0.03 + p) * s * 0.15, c);
        ellipse(s * 0.62, 0, s * 0.18, s * 0.2); ctx.fillStyle = c.ink; ctx.fill();
        ellipse(0, 0, s * 0.55, s * 0.45); fillEdge(fill, c);
        ctx.strokeStyle = c.edge; ctx.lineWidth = 1.2; ctx.beginPath(); ctx.moveTo(s * 0.4, 0); ctx.lineTo(-s * 0.55, 0); ctx.stroke();
        ctx.fillStyle = "rgba(255,255,255,0.25)"; ellipse(s * 0.1, -s * 0.2, s * 0.18, s * 0.08, -0.3); ctx.fill();
      },
      ant: function (s, t, p, fill, c) {
        legs(s, 3, s * 0.45, s * 0.42, Math.sin(t * 0.05 + p) * s * 0.18, c);
        ctx.fillStyle = fill;
        ellipse(-s * 0.45, 0, s * 0.3, s * 0.22); ctx.fill();
        ellipse(0, 0, s * 0.18, s * 0.12); ctx.fill();
        ellipse(s * 0.38, 0, s * 0.18, s * 0.16); ctx.fill();
        ctx.strokeStyle = fill; ctx.lineWidth = Math.max(1, s * 0.06);
        ctx.beginPath(); ctx.moveTo(s * 0.5, -s * 0.08); ctx.lineTo(s * 0.75, -s * 0.25); ctx.moveTo(s * 0.5, s * 0.08); ctx.lineTo(s * 0.75, s * 0.25); ctx.stroke();
      },
      duck: function (s, t, p, fill, c) {
        var paddle = Math.sin(t * 0.012 + p) * s * 0.04;
        ctx.globalAlpha = 0.35; ctx.strokeStyle = c.wool; ctx.lineWidth = 1;
        ctx.beginPath(); ctx.arc(-s * 0.2, 0, s * (0.75 + paddle / s), Math.PI * 0.65, Math.PI * 1.35); ctx.stroke(); ctx.globalAlpha = 1;
        ellipse(-s * 0.05, 0, s * 0.55, s * 0.4); fillEdge(fill, c);
        ellipse(-s * 0.15, 0, s * 0.3, s * 0.25); ctx.fillStyle = "rgba(0,0,0,0.12)"; ctx.fill();
        ellipse(s * 0.45, 0, s * 0.25, s * 0.24); fillEdge(fill, c);
        ellipse(s * 0.72, 0, s * 0.15, s * 0.08); ctx.fillStyle = c.warm; ctx.fill();
      },
      firefly: function (s, t, p, fill, c, glow) {
        var light = Math.max(0, Math.min(1, glow));
        if (light > 0.02) {
          var g = ctx.createRadialGradient(-s * 0.2, 0, 0, -s * 0.2, 0, s * 2.6);
          g.addColorStop(0, "rgba(255, 226, 120," + (0.85 * light) + ")");
          g.addColorStop(1, "rgba(255, 226, 120, 0)");
          ctx.fillStyle = g; ellipse(-s * 0.2, 0, s * 2.6, s * 2.6); ctx.fill();
        }
        ctx.globalAlpha = 0.45; ctx.fillStyle = c.wool;
        [-1, 1].forEach(function (side) { ellipse(s * 0.05, side * s * 0.3, s * 0.26, s * 0.14, side * 0.5); ctx.fill(); });
        ctx.globalAlpha = 1;
        ellipse(s * 0.15, 0, s * 0.3, s * 0.16); ctx.fillStyle = c.ink; ctx.fill();
        ellipse(-s * 0.3, 0, s * 0.24, s * 0.17); ctx.fillStyle = light > 0.02 ? "#ffe27a" : c.gold; ctx.fill();
      },
      person: function (s, t, p, fill, c) {
        var swing = Math.sin(t * 0.012 + p) * s * 0.18;
        ctx.fillStyle = c.edge;
        ellipse(swing, -s * 0.45, s * 0.14, s * 0.09); ctx.fill();
        ellipse(-swing, s * 0.45, s * 0.14, s * 0.09); ctx.fill();
        ellipse(0, 0, s * 0.3, s * 0.52); fillEdge(fill, c);
        ellipse(s * 0.05, 0, s * 0.25, s * 0.25); fillEdge(c.fur, c, 1);
      },
      leaf: function (s, t, p, fill, c) {
        ctx.rotate(p);
        ctx.beginPath(); ctx.moveTo(-s, 0); ctx.quadraticCurveTo(0, -s * 0.7, s, 0); ctx.quadraticCurveTo(0, s * 0.7, -s, 0);
        fillEdge(fill === c.ink ? c.leaf : fill, c, 1);
        ctx.strokeStyle = c.edge; ctx.lineWidth = 0.8; ctx.beginPath(); ctx.moveTo(-s, 0); ctx.lineTo(s * 0.8, 0); ctx.stroke();
      },
      spark: function (s, t, p, fill, c) {
        var g = ctx.createRadialGradient(0, 0, 0, 0, 0, s * 2.2);
        g.addColorStop(0, fill); g.addColorStop(1, "rgba(0,0,0,0)");
        ctx.fillStyle = g; ctx.globalAlpha = 0.6; ellipse(0, 0, s * 2.2, s * 2.2); ctx.fill(); ctx.globalAlpha = 1;
        ellipse(0, 0, s, s * 0.7); ctx.fillStyle = fill; ctx.fill();
      }
    };
    // Other names for the same animals.
    sprites.child = function (s, t, p, fill, c) { sprites.person(s * 0.8, t, p, fill, c); };
    sprites.duckling = function (s, t, p, fill, c) { sprites.duck(s, t, p, fill === c.ink ? c.gold : fill, c); };
    sprites.grazer = sprites.deer;
    sprites.hunter = sprites.wolf;

    // Shapes that do not turn with the direction of the boid.
    var still = { leaf: true, spark: true };

    // The shadow of a shape: its half length and its half width, as parts
    // of the size. A person is wider across than along its way.
    var shadows = { person: [0.42, 0.62], child: [0.36, 0.52], sheep: [0.75, 0.6], beetle: [0.65, 0.5], bee: [0.6, 0.45], duck: [0.6, 0.45], duckling: [0.6, 0.45], firefly: [0.4, 0.3], leaf: [0.9, 0.5], spark: [0.5, 0.5] };

    // --- The grounds --------------------------------------------------
    //
    // `ground` of the header: grass, water, sand, floor or night. The
    // ground is drawn one time in a canvas of its own, then copied at
    // each frame.
    var groundCanvas = null;
    var groundKey = "";

    function seeded(n) {
      var x = Math.sin(n * 12.9898) * 43758.5453;
      return x - Math.floor(x);
    }

    function paintGround(kind, c, width, height) {
      var g = document.createElement("canvas");
      g.width = width; g.height = height;
      var gx = g.getContext("2d");
      var base = { grass: c.grass, water: c.water, sand: c.sand, floor: c.floor, night: c.night }[kind] || c.field;
      gx.fillStyle = base; gx.fillRect(0, 0, width, height);
      var count = Math.round(width * height / 2600);
      for (var i = 0; i < count; i++) {
        var x = seeded(i + 1) * width, y = seeded(i + 7.3) * height, r = 1 + seeded(i + 3.1) * 3;
        if (kind === "grass") {
          gx.strokeStyle = c.leaf; gx.globalAlpha = 0.12 + seeded(i) * 0.12; gx.lineWidth = 1.2;
          gx.beginPath(); gx.moveTo(x, y); gx.lineTo(x - r, y - r * 2.2); gx.moveTo(x, y); gx.lineTo(x + r * 0.6, y - r * 2.6); gx.stroke();
        } else if (kind === "water") {
          if (i % 3 === 0) { gx.strokeStyle = c.cool; gx.globalAlpha = 0.1; gx.lineWidth = 1.5; gx.beginPath(); gx.arc(x, y, r * 6, Math.PI * 1.15, Math.PI * 1.85); gx.stroke(); }
        } else if (kind === "sand") {
          gx.fillStyle = c.fur; gx.globalAlpha = 0.08 + seeded(i) * 0.08; gx.fillRect(x, y, r * 0.7, r * 0.7);
        } else if (kind === "night") {
          if (i % 2 === 0) { gx.fillStyle = "#cfe0ff"; gx.globalAlpha = seeded(i + 2) * 0.5; gx.fillRect(x, y, 1.4, 1.4); }
        }
      }
      if (kind === "floor") {
        gx.strokeStyle = c.edge; gx.globalAlpha = 0.08; gx.lineWidth = 1;
        var step = width / 32;
        for (var a = step; a < width; a += step) { gx.beginPath(); gx.moveTo(a, 0); gx.lineTo(a, height); gx.stroke(); }
        for (var b = step; b < height; b += step) { gx.beginPath(); gx.moveTo(0, b); gx.lineTo(width, b); gx.stroke(); }
      }
      gx.globalAlpha = 1;
      return g;
    }

    // The ground has the frame of the screen: its grass grows up on the
    // screen, also when the world is turned.
    function ground(c, width, height) {
      var key = run.ground + "|" + c.field + "|" + c.grass + "|" + width + "x" + height;
      if (!run.ground) { return; }
      if (key !== groundKey) { groundCanvas = paintGround(run.ground, c, width, height); groundKey = key; }
      ctx.drawImage(groundCanvas, 0, 0);
    }

    // A zone: a part of the box with a color, round corners and a line of
    // dashes; `zone[5]` is an optional label.
    function zone(z, c, scale, height) {
      var x = z[0] * scale, y = (height - z[3]) * scale, w = (z[2] - z[0]) * scale, h = (z[3] - z[1]) * scale;
      var r = Math.min(14, w / 4, h / 4);
      ctx.beginPath();
      ctx.roundRect ? ctx.roundRect(x, y, w, h, r) : ctx.rect(x, y, w, h);
      ctx.fillStyle = c[z[4]] || c.cool;
      // A zone with a label is a place (a pen, an exit): it has a line of
      // dashes. A zone with no label (a path, a post) has only a soft fill.
      ctx.globalAlpha = z[5] ? 0.16 : 0.22; ctx.fill();
      if (z[5]) {
        ctx.globalAlpha = 0.45; ctx.strokeStyle = c[z[4]] || c.cool; ctx.lineWidth = 2; ctx.setLineDash([8, 6]); ctx.stroke(); ctx.setLineDash([]);
      }
      ctx.globalAlpha = 1;
      if (z[5]) {
        var text = String(z[5]);
        ctx.fillStyle = c[z[4]] || c.cool; ctx.font = "600 " + Math.round(W / 55 * boost) + "px sans-serif";
        ctx.textAlign = "center";
        // The width and the height of the zone on the screen.
        var across = turn ? h : w, tall = turn ? w : h;
        if (ctx.measureText(text).width > across - 12 && tall > across) {
          // A tall, narrow zone: the label goes along its long side.
          upright(x + w / 2, y + h / 2, function () {
            ctx.rotate(-Math.PI / 2); ctx.textBaseline = "middle"; ctx.fillText(text, 0, 0);
          });
        } else {
          // The middle of the top side of the zone on the screen.
          var top = turn === 1 ? [x + w - 6, y + h / 2] : (turn === -1 ? [x + 6, y + h / 2] : [x + w / 2, y + 6]);
          upright(top[0], top[1], function () { ctx.textBaseline = "top"; ctx.fillText(text, 0, 0); });
        }
      }
    }

    // A rock of the world: a stone with a light side.
    function stone(x, y, r, c, number) {
      upright(x, y, function () {
        ctx.fillStyle = c.shade; ellipse(r * 0.12, r * 0.16, r * 1.02, r * 0.96); ctx.fill();
        ctx.fillStyle = c.rock; rock(number, r, 0);
        ctx.fillStyle = "rgba(255,255,255,0.18)"; ellipse(-r * 0.25, -r * 0.3, r * 0.45, r * 0.3, -0.5); ctx.fill();
      });
    }

    function draw(now) {
      requestAnimationFrame(draw);
      if (!run || !last) { return; }
      var part = paused ? 1 : Math.min((now - lastAt) / period, 1);
      var scale = W / run.box[0];
      var height = run.box[1];
      var c = colors();
      var at = {};
      var list = [];
      var view = { turn: turn, upright: upright };

      for (var i = 0; i < last.b.length; i += 6) {
        var was = before[last.b[i]] || [last.b[i + 1], last.b[i + 2], last.b[i + 3]];
        var boid = {
          x: between(was[0], last.b[i + 1], run.box[0], part) * scale,
          y: (height - between(was[1], last.b[i + 2], height, part)) * scale,
          angle: sweep(was[2], last.b[i + 3], part),
          kind: run.kinds[last.b[i + 4]] || run.kinds[0],
          size: last.b[i + 5],
          number: last.b[i]
        };
        at[boid.number] = boid;
        list.push(boid);
      }
      shown = list;

      // The view: the world as it is, turned, or a part of it.
      camera(list, now);
      ctx.setTransform(1, 0, 0, 1, 0, 0);
      ctx.clearRect(0, 0, canvas.width, canvas.height);
      if (turn) {
        ground(c, H, W);
        if (turn === 1) { ctx.setTransform(0, -1, 1, 0, 0, W); } else { ctx.setTransform(0, 1, -1, 0, H, 0); }
      } else {
        ctx.setTransform(1, 0, 0, 1, -cam.x, 0);
        ground(c, W, H);
      }

      // A zone is a part of the box with a color, behind the boids.
      (run.zones || []).forEach(function (one) { zone(one, c, scale, height); });

      run.rocks.forEach(function (one, n) { stone(one[0] * scale, (height - one[1]) * scale, one[2] * scale, c, n + 3); });

      // A page can draw things of its own on the ground, under the boids.
      if (options.beneath) { options.beneath(ctx, scale, height, c, now, sprites, view); }

      if (showLinks) {
        ctx.strokeStyle = c.cool;
        ctx.globalAlpha = 0.4;
        ctx.lineWidth = 1.5;
        links.forEach(function (link) {
          var from = at[link[0]], to = at[link[1]];
          if (!from || !to) { return; }
          if (Math.abs(from.x - to.x) > W / 2 || Math.abs(from.y - to.y) > H / 2) { return; }
          ctx.beginPath();
          ctx.moveTo(from.x, from.y);
          ctx.lineTo(to.x, to.y);
          ctx.stroke();
        });
        ctx.globalAlpha = 1;
      }

      // The rocks first, so that the other boids are on top.
      list.sort(function (a, b) { return (a.kind.shape === "rock" ? 0 : 1) - (b.kind.shape === "rock" ? 0 : 1); });
      list.forEach(function (boid) {
        var size = boid.kind.size * scale * (boid.kind.shape === "rock" || boid.kind.shape === "dot" ? 1 : boost);
        ctx.save();
        ctx.translate(boid.x, boid.y);
        ctx.fillStyle = c[boid.kind.color] || c.ink;
        var sprite = sprites[boid.kind.shape];
        if (sprite) {
          var phase = (boid.number % 997) / 997 * 2 * Math.PI;
          // An animal is drawn larger than its place in the world, so
          // that a person sees its shape on a small screen.
          var body = size * 1.5;
          // A shadow under the animal, then the animal in its direction.
          var shadow = shadows[boid.kind.shape] || [0.75, 0.42];
          var lower = fromScreen(body * 0.12, body * 0.18);
          ctx.fillStyle = c.shade;
          ellipse(lower[0], lower[1], body * shadow[0], body * shadow[1], -boid.angle);
          ctx.fill();
          ctx.save();
          if (!still[boid.kind.shape]) { ctx.rotate(-boid.angle); }
          sprite(body, now, phase, c[boid.kind.color] || c.ink, c, boid.size / 10);
          ctx.restore();
          // A kind with a badge shows the size of the boid as a number
          // (for example the health of a large beetle).
          if (boid.kind.badge && boid.size > 0) {
            upright(0, 0, function () {
              ctx.font = "700 " + Math.round(body * 0.7) + "px sans-serif";
              ctx.textAlign = "center"; ctx.textBaseline = "middle";
              ctx.lineWidth = 3; ctx.strokeStyle = c.panel; ctx.strokeText(String(boid.size), 0, -body * 0.95);
              ctx.fillStyle = c.ink; ctx.fillText(String(boid.size), 0, -body * 0.95);
            });
          }
        } else if (boid.kind.shape === "rock") {
          rock(boid.number, size * Math.max(boid.size, 1), now);
        } else if (boid.kind.shape === "dot") {
          ctx.beginPath();
          ctx.arc(0, 0, size, 0, 2 * Math.PI);
          ctx.fill();
        } else if (boid.kind.shape === "hex") {
          ctx.beginPath();
          for (var k = 0; k < 6; k++) { ctx.lineTo(size * Math.cos(k * Math.PI / 3), size * Math.sin(k * Math.PI / 3)); }
          ctx.closePath();
          ctx.fill();
          if (boid.size > 1) {
            // The hits that the boid can take.
            upright(0, 0, function () {
              ctx.fillStyle = c.panel;
              ctx.font = "600 " + Math.round(size * 0.9) + "px sans-serif";
              ctx.textAlign = "center";
              ctx.textBaseline = "middle";
              ctx.fillText(String(boid.size), 0, size * 0.07);
            });
          }
        } else {
          ctx.rotate(-boid.angle);
          if (boid.kind.shape === "ship" && extra.thrust) {
            ctx.fillStyle = c.rock;
            ctx.beginPath();
            ctx.moveTo(-size * 0.5, size * 0.3);
            ctx.lineTo(-size * 1.4, 0);
            ctx.lineTo(-size * 0.5, -size * 0.3);
            ctx.fill();
            ctx.fillStyle = c[boid.kind.color];
          }
          dart(size);
          if (boid.kind.shape === "ship" && extra.safe) {
            ctx.strokeStyle = c[boid.kind.color];
            ctx.lineWidth = 1.5;
            ctx.setLineDash([6, 6]);
            ctx.beginPath();
            ctx.arc(0, 0, size * 1.7, 0, 2 * Math.PI);
            ctx.stroke();
            ctx.setLineDash([]);
          }
        }
        ctx.restore();
      });

      // A page can draw things of its own over the boids.
      if (options.above) { options.above(ctx, scale, height, c, now, sprites, view); }
    }

    // The point of the world under a pointer event, or null.
    function toWorld(event) {
      if (!run) { return null; }
      var rect = canvas.getBoundingClientRect();
      var fx = (event.clientX - rect.left) / rect.width, fy = (event.clientY - rect.top) / rect.height;
      var x, y;
      if (turn === 1) { x = (1 - fy) * run.box[0]; y = (1 - fx) * run.box[1]; }
      else if (turn === -1) { x = fy * run.box[0]; y = fx * run.box[1]; }
      else { x = (fx * canvas.width + cam.x) / W * run.box[0]; y = (1 - fy) * run.box[1]; }
      return [Math.round(x * 10) / 10, Math.round(y * 10) / 10];
    }

    // The boids of the last frame (of one kind, or all), for the checks of
    // the site: the point of each one in the world and on the screen, and
    // its angle.
    function where(name) {
      var rect = canvas.getBoundingClientRect();
      var scale = W / (run ? run.box[0] : 160);
      return shown.filter(function (boid) { return !name || boid.kind.name === name; }).map(function (boid) {
        var point = toCanvas(boid.x, boid.y);
        return {
          x: boid.x / scale, y: (run.box[1] * scale - boid.y) / scale, angle: boid.angle,
          left: rect.left + point[0] * rect.width / canvas.width, top: rect.top + point[1] * rect.height / canvas.height
        };
      });
    }

    function send(message) {
      if (socket && socket.readyState === 1) { socket.send(JSON.stringify(message)); return true; }
      return false;
    }

    function connect() {
      var scheme = location.protocol === "https:" ? "wss://" : "ws://";
      note("Connecting");
      socket = new WebSocket(scheme + location.host + "/ws/" + options.name);
      socket.onopen = function () {
        tries = 0;
        note("Connected");
        if (options.onOpen) { options.onOpen(); }
      };
      socket.onmessage = function (event) {
        var message = JSON.parse(event.data);
        if (message.start) { start(message.start); }
        if (message.m && !paused) { take(message.m); }
        if (message.error) {
          note("No scene");
          if (options.onError) { options.onError(message.error); }
        }
      };
      socket.onclose = function () {
        // Try again 3 times, then wait for the visitor.
        if (tries < 3) { tries++; note("Connecting again"); setTimeout(connect, 1500 * tries); } else { note("No connection to the server"); }
      };
    }

    // The server closes a connection that sends nothing for 2 minutes.
    setInterval(function () { send({ping: 1}); }, 30000);
    connect();
    requestAnimationFrame(draw);

    var self = {
      send: send,
      pause: function () { paused = !paused; lastAt = performance.now(); return paused; },
      links: function () { showLinks = !showLinks; return showLinks; },
      toWorld: toWorld,
      direction: direction,
      where: where,
      // The view now, for the checks of the site: the turn, and the pixels
      // of the screen for one unit of the world.
      view: function () {
        var rect = canvas.getBoundingClientRect();
        return { turn: turn, crop: !!crop, phone: onField, boost: boost, unit: rect.width / canvas.width * W / (run ? run.box[0] : 160) };
      }
    };
    scenes.push(self);
    return self;
  }

  // The scenes of the page.
  var scenes = [];

  // A button that changes a state of the scene.
  function toggle(button, change, labels) {
    button.addEventListener("click", function () {
      var on = change();
      button.setAttribute("aria-pressed", on ? "true" : "false");
      if (labels) { button.textContent = on ? labels[1] : labels[0]; }
    });
  }

  window.Boids = { scene: scene, toggle: toggle, scenes: scenes };
})();
