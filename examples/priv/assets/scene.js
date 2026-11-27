// A scene of the site of boids: a WebSocket to a world with boids
// on the server, and a canvas that draws each moment of these boids.
//
//   var scene = Boids.scene({name: "game", canvas: element, readings: element, source: element});
//   scene.send({keys: ["left"]});
(function () {
  "use strict";

  function scene(options) {
    var canvas = options.canvas;
    var ctx = canvas.getContext("2d");
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
      canvas.width = 1600;
      canvas.height = Math.round(1600 * run.box[1] / run.box[0]);
      if (options.readings) { options.readings.textContent = ""; }
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
      if (!options.readings) { return; }
      var id = "reading-" + label.replace(/\W+/g, "-");
      var element = document.getElementById(id);
      if (!element) {
        element = document.createElement("div");
        element.className = "reading";
        element.id = id;
        element.appendChild(document.createElement("span")).textContent = label;
        element.appendChild(document.createElement("b"));
        options.readings.appendChild(element);
      }
      element.lastChild.textContent = value;
    }

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

    function turn(a, b, part) {
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

    function ground(c) {
      var key = run.ground + "|" + c.field + "|" + c.grass + "|" + canvas.width + "x" + canvas.height;
      if (!run.ground) { return; }
      if (key !== groundKey) { groundCanvas = paintGround(run.ground, c, canvas.width, canvas.height); groundKey = key; }
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
        ctx.fillStyle = c[z[4]] || c.cool; ctx.font = "600 " + Math.round(canvas.width / 55) + "px sans-serif";
        ctx.textAlign = "center"; ctx.textBaseline = "top";
        if (ctx.measureText(String(z[5])).width > w - 12 && h > w) {
          // A tall, narrow zone: the label goes along its long side.
          ctx.save(); ctx.translate(x + w / 2, y + h / 2); ctx.rotate(-Math.PI / 2);
          ctx.textBaseline = "middle"; ctx.fillText(String(z[5]), 0, 0); ctx.restore();
        } else {
          ctx.fillText(String(z[5]), x + w / 2, y + 6);
        }
      }
    }

    // A rock of the world: a stone with a light side.
    function stone(x, y, r, c, number) {
      ctx.save(); ctx.translate(x, y);
      ctx.fillStyle = c.shade; ellipse(r * 0.12, r * 0.16, r * 1.02, r * 0.96); ctx.fill();
      ctx.fillStyle = c.rock; rock(number, r, 0);
      ctx.fillStyle = "rgba(255,255,255,0.18)"; ellipse(-r * 0.25, -r * 0.3, r * 0.45, r * 0.3, -0.5); ctx.fill();
      ctx.restore();
    }

    function draw(now) {
      requestAnimationFrame(draw);
      if (!run || !last) { return; }
      var part = paused ? 1 : Math.min((now - lastAt) / period, 1);
      var scale = canvas.width / run.box[0];
      var height = run.box[1];
      var c = colors();
      var at = {};
      var list = [];
      ctx.clearRect(0, 0, canvas.width, canvas.height);
      ground(c);

      // A zone is a part of the box with a color, behind the boids.
      (run.zones || []).forEach(function (one) { zone(one, c, scale, height); });

      run.rocks.forEach(function (one, n) { stone(one[0] * scale, (height - one[1]) * scale, one[2] * scale, c, n + 3); });

      // A page can draw things of its own on the ground, under the boids.
      if (options.beneath) { options.beneath(ctx, scale, height, c, now, sprites); }

      for (var i = 0; i < last.b.length; i += 6) {
        var was = before[last.b[i]] || [last.b[i + 1], last.b[i + 2], last.b[i + 3]];
        var boid = {
          x: between(was[0], last.b[i + 1], run.box[0], part) * scale,
          y: (height - between(was[1], last.b[i + 2], height, part)) * scale,
          angle: turn(was[2], last.b[i + 3], part),
          kind: run.kinds[last.b[i + 4]] || run.kinds[0],
          size: last.b[i + 5],
          number: last.b[i]
        };
        at[boid.number] = boid;
        list.push(boid);
      }

      if (showLinks) {
        ctx.strokeStyle = c.cool;
        ctx.globalAlpha = 0.4;
        ctx.lineWidth = 1.5;
        links.forEach(function (link) {
          var from = at[link[0]], to = at[link[1]];
          if (!from || !to) { return; }
          if (Math.abs(from.x - to.x) > canvas.width / 2 || Math.abs(from.y - to.y) > canvas.height / 2) { return; }
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
        var size = boid.kind.size * scale;
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
          ctx.fillStyle = c.shade;
          ellipse(body * 0.12, body * 0.18, body * 0.75, body * 0.42, -boid.angle);
          ctx.fill();
          ctx.save();
          if (!still[boid.kind.shape]) { ctx.rotate(-boid.angle); }
          sprite(body, now, phase, c[boid.kind.color] || c.ink, c, boid.size / 10);
          ctx.restore();
          // A kind with a badge shows the size of the boid as a number
          // (for example the health of a large beetle).
          if (boid.kind.badge && boid.size > 0) {
            ctx.font = "700 " + Math.round(body * 0.7) + "px sans-serif";
            ctx.textAlign = "center"; ctx.textBaseline = "middle";
            ctx.lineWidth = 3; ctx.strokeStyle = c.panel; ctx.strokeText(String(boid.size), 0, -body * 0.95);
            ctx.fillStyle = c.ink; ctx.fillText(String(boid.size), 0, -body * 0.95);
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
            ctx.fillStyle = c.panel;
            ctx.font = "600 " + Math.round(size * 0.9) + "px sans-serif";
            ctx.textAlign = "center";
            ctx.textBaseline = "middle";
            ctx.fillText(String(boid.size), 0, size * 0.07);
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

    return {
      send: send,
      pause: function () { paused = !paused; lastAt = performance.now(); return paused; },
      links: function () { showLinks = !showLinks; return showLinks; }
    };
  }

  // A button that changes a state of the scene.
  function toggle(button, change, labels) {
    button.addEventListener("click", function () {
      var on = change();
      button.setAttribute("aria-pressed", on ? "true" : "false");
      if (labels) { button.textContent = on ? labels[1] : labels[0]; }
    });
  }

  window.Boids = { scene: scene, toggle: toggle };
})();
