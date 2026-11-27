// A scene of the site of boids: a WebSocket to an environment with boids
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
      return { ink: read("--boid"), rock: read("--rock"), warm: read("--warm"), cool: read("--cool"), panel: read("--panel") };
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

      ctx.fillStyle = c.rock;
      run.rocks.forEach(function (one) {
        ctx.beginPath();
        ctx.arc(one[0] * scale, (height - one[1]) * scale, one[2] * scale, 0, 2 * Math.PI);
        ctx.fill();
      });

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
        if (boid.kind.shape === "rock") {
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
