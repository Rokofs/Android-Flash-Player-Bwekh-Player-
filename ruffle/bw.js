// Bwekh Player: host page for Ruffle (runs inside RuffleActivity's WebView).
// Settings come in the "c" query parameter (JSON), the app is reached through window.Bwekh.
(function () {
	"use strict";

	var cfg = {};
	try { cfg = JSON.parse(new URLSearchParams(location.search).get("c") || "{}"); } catch (e) { cfg = {}; }
	var app = window.Bwekh || null;
	function tell(name, arg) { try { if (app) app.event(name, arg == null ? "" : String(arg)); } catch (e) {} }

	// ---------------------------------------------------------------- sound
	// every AudioContext Ruffle makes is remembered, so leaving the game really stops the sound
	// (a WebView can keep playing for a while after its activity is gone)
	var audioCtxs = [];
	(function () {
		var names = ["AudioContext", "webkitAudioContext"];
		names.forEach(function (n) {
			var Real = window[n];
			if (typeof Real !== "function") return;
			var Wrapped = function (opts) {
				var c = opts === undefined ? new Real() : new Real(opts);
				audioCtxs.push(c);
				return c;
			};
			Wrapped.prototype = Real.prototype;
			try { Object.setPrototypeOf(Wrapped, Real); } catch (e) {}
			window[n] = Wrapped;
		});
	})();
	function audioOff(close) {
		audioCtxs.forEach(function (c) {
			try { if (close) c.close(); else if (c.state === "running") c.suspend(); } catch (e) {}
		});
		if (close) audioCtxs = [];
	}
	function audioOn() {
		audioCtxs.forEach(function (c) { try { if (c.state === "suspended") c.resume(); } catch (e) {} });
	}

	// ---------------------------------------------------------------- old WebViews
	// Android 7 / 32-bit phones often have an old WebView: fill in what Ruffle needs from newer ones
	var chrome = (function () {
		var m = /Chrome\/(\d+)/.exec(navigator.userAgent || "");
		return m ? parseInt(m[1], 10) : 0;
	})();
	var arm32 = /armv7|armv8l|arm32|armeabi/i.test(navigator.platform + " " + navigator.userAgent);
	try { if (typeof globalThis === "undefined") window.globalThis = window; } catch (e) {}
	if (typeof window.queueMicrotask !== "function") {
		window.queueMicrotask = function (fn) { Promise.resolve().then(fn); };
	}
	if (!Object.fromEntries) {
		Object.fromEntries = function (it) {
			var o = {};
			Array.from(it).forEach(function (kv) { o[kv[0]] = kv[1]; });
			return o;
		};
	}
	if (window.Intl) {
		var RealLocale = Intl.Locale;
		var localeOk = false;
		try { localeOk = !!RealLocale && !!new RealLocale(navigator.language || "en"); } catch (e) { localeOk = false; }
		if (!localeOk) {
			Intl.Locale = function (tag) {
				if (RealLocale) { try { return new RealLocale(tag); } catch (e) { try { return new RealLocale("en"); } catch (e2) {} } }
				tag = String(tag || "en");
				this.baseName = tag;
				this.language = tag.split("-")[0];
				this.textInfo = { direction: "ltr" };
				this.toString = function () { return tag; };
			};
		}
	}

	/** can this WebView run Ruffle's WebAssembly at all? (needs sign-extension ops: Chrome 74+) */
	function wasmOk() {
		try {
			if (typeof WebAssembly !== "object" || !WebAssembly.validate) return false;
			// (func (result i32) i32.const 0 i32.extend8_s)
			return WebAssembly.validate(new Uint8Array([0, 97, 115, 109, 1, 0, 0, 0, 1, 5, 1, 96, 0, 1, 127,
				3, 2, 1, 0, 10, 7, 1, 5, 0, 65, 0, 192, 11]));
		} catch (e) { return false; }
	}

	function webViewName() {
		return chrome ? "Chrome/WebView " + chrome : (navigator.userAgent || "unknown browser").slice(0, 80);
	}

	// ---------------------------------------------------------------- failure screen
	var failed = false;

	/** Ruffle can't play here: say why and offer the built-in engine */
	function fail(reason, tooOld) {
		if (failed) return;
		failed = true;
		clearTimeout(watchdog);
		tell(tooOld ? "unsupported" : "error", reason);
		var box = document.getElementById("fail");
		document.getElementById("failText").textContent = reason;
		document.getElementById("failInfo").textContent = webViewName() + (arm32 ? " · 32-bit" : "") +
			(renderer() ? " · renderer: " + renderer() : "");
		var fb = document.getElementById("failFallback");
		if (cfg.fallback) {
			fb.textContent = "Play with " + cfg.fallback;
			fb.style.display = "";
		} else {
			fb.style.display = "none";
		}
		document.getElementById("failRenderer").style.display = tooOld ? "none" : "";
		box.classList.add("open");
	}

	var watchdog = 0;

	window.addEventListener("error", function (ev) {
		if (started) return; // errors once the game runs are the game's business
		var msg = ev && ev.message ? ev.message : "script error";
		fail("Ruffle couldn't start: " + msg, false);
	});

	// ---------------------------------------------------------------- renderer
	// wgpu (Ruffle's default) shows only black on some old / 32-bit phones; WebGL is safer there
	var RENDERERS = ["", "webgl", "canvas"];
	function renderer() {
		var r = null;
		try { r = localStorage.getItem("renderer"); } catch (e) {}
		if (r !== null && RENDERERS.indexOf(r) >= 0) return r;
		return (arm32 || (chrome && chrome < 90)) ? "webgl" : "";
	}
	function setRenderer(r) {
		try { localStorage.setItem("renderer", r); } catch (e) {}
	}
	function rendererName(r) {
		return r === "webgl" ? "WebGL" : r === "canvas" ? "Canvas (slow, safest)" : "Auto";
	}

	// ---------------------------------------------------------------- render resolution
	// Ruffle sizes its canvas by devicePixelRatio: a smaller ratio = fewer pixels to draw.
	var realDpr = window.devicePixelRatio || 1;
	if (cfg.renderRes > 0) {
		try {
			Object.defineProperty(window, "devicePixelRatio", {
				configurable: true,
				get: function () {
					var h = Math.max(1, Math.min(window.innerWidth, window.innerHeight));
					return Math.min(realDpr, cfg.renderRes / h);
				}
			});
		} catch (e) {}
	}

	// ---------------------------------------------------------------- Ruffle
	var player = null, api = null, paused = false;

	function rufflePlayer() {
		if (!wasmOk()) {
			fail("This phone's WebView is too old for Ruffle. Update \"Android System WebView\" " +
				"(or Chrome) in Google Play and try again.", true);
			return;
		}
		watchLeaving();
		window.RufflePlayer = window.RufflePlayer || {};
		window.RufflePlayer.config = {
			publicPath: "/ruffle/",
			polyfills: false,
			autoplay: "on",
			unmuteOverlay: "hidden",
			splashScreen: false,
			letterbox: "on",
			contextMenu: "off",
			showSwfDownload: false,
			warnOnUnsupportedContent: false,
			openUrlMode: "confirm", // Ruffle asks window.confirm, which watchLeaving answers
			allowFullscreen: false,
			logLevel: cfg.debug ? "info" : "error",
			quality: cfg.quality || "high",
			backgroundColor: null
		};
		var r = renderer();
		if (r) window.RufflePlayer.config.preferredRenderer = r;
		var s = document.createElement("script");
		s.src = "/ruffle/ruffle.js";
		s.onload = start;
		s.onerror = function () { fail("Ruffle's files couldn't be loaded.", false); };
		// nothing on screen after a while: tell the player instead of a black screen
		watchdog = setTimeout(function () {
			if (!started) fail("Ruffle didn't start in time.", false);
		}, 25000);
		document.head.appendChild(s);
	}

	var started = false;

	function start() {
		if (failed) return;
		var ruffle;
		try {
			ruffle = window.RufflePlayer.newest();
			player = ruffle.createPlayer();
		} catch (e) {
			fail("Ruffle couldn't start: " + (e && e.message ? e.message : e), false);
			return;
		}
		document.getElementById("game").appendChild(player);
		api = typeof player.ruffle === "function" ? player.ruffle() : player;
		player.addEventListener("loadedmetadata", function () {
			started = true;
			clearTimeout(watchdog);
			tell("ready");
			focusGame();
		});
		var p;
		// games' "Exit" buttons: getURL("javascript:window.close()") or fscommand("quit") close the player.
		// Script access is on for that; the page is ours and has nothing to reach.
		window.close = function () { setTimeout(exit, 0); };
		try { player.onFSCommand = function (cmd) { if (String(cmd).toLowerCase() === "quit") { setTimeout(exit, 0); return true; } return false; }; } catch (e) {}
		try { p = api.load({ url: cfg.swf, allowScriptAccess: true }); }
		catch (e) { fail("Ruffle couldn't open the file: " + (e && e.message ? e.message : e), false); return; }
		if (p && p.then) p.then(function () { focusGame(); },
			function (e) { fail("Ruffle couldn't open the file: " + (e && e.message ? e.message : e), false); });
		player.addEventListener("pointerdown", function () { activity(); });
	}

	/** Ruffle only takes keys while it has focus; a tap on the game gives it, so do the same */
	function focusGame() {
		if (!player) return;
		try { player.focus({ preventScroll: true }); } catch (e) {}
	}

	function keyTarget() {
		if (!player) return null;
		return player;
	}

	// a held key repeats like a real keyboard: many old games move by "key down" events
	var REPEAT_DELAY = 350, REPEAT_EVERY = 50;
	var repeats = {};  // key code -> timer

	function startRepeat(k) {
		stopRepeat(k.kc);
		repeats[k.kc] = setTimeout(function tick() {
			if (!(held[k.kc] > 0) || paused) { delete repeats[k.kc]; return; }
			sendKey(k, true, true);
			repeats[k.kc] = setTimeout(tick, REPEAT_EVERY);
		}, REPEAT_DELAY);
	}

	function stopRepeat(kc) {
		if (repeats[kc]) { clearTimeout(repeats[kc]); delete repeats[kc]; }
	}

	function sendKey(k, down, repeat) {
		var t = keyTarget();
		if (!t) return;
		if (down) focusGame();
		var ev = new KeyboardEvent(down ? "keydown" : "keyup", {
			key: k.key, code: k.code, location: k.loc || 0, repeat: !!repeat,
			bubbles: true, cancelable: true, composed: true
		});
		try {
			Object.defineProperty(ev, "keyCode", { get: function () { return k.kc; } });
			Object.defineProperty(ev, "which", { get: function () { return k.kc; } });
		} catch (e) {}
		t.dispatchEvent(ev);
	}

	// ---------------------------------------------------------------- gamepad
	var pad = cfg.pad || null;
	var padShown = !!(pad && pad.show);
	var dpadEl = null, btnEl = null, dirEls = [], btnEls = [];
	var R, BR, BD;
	var held = {};       // key code -> number of fingers holding it
	var pointers = {};   // pointerId -> [codes]
	var origins = {};    // pointerId -> "dpad" | "btn"
	var keyByCode = {};

	function buildPad() {
		if (!pad) return;
		var sc = pad.scale > 0 ? pad.scale : 1;
		R = 68 * sc; BR = 30 * sc; BD = 50 * sc;
		var ext = Math.max(R * 1.15, BD + BR * 1.3);
		var op = pad.opacity > 0 ? pad.opacity : 0.5;

		dpadEl = document.createElement("div");
		dpadEl.className = "pad";
		dpadEl.style.width = dpadEl.style.height = (ext * 2) + "px";
		dpadEl.style.opacity = op;
		var ring = document.createElement("div");
		ring.className = "ring";
		place(ring, ext, ext, R);
		dpadEl.appendChild(ring);
		var arrows = ["▲", "▼", "◀", "▶"], dirs = [[0, -1], [0, 1], [-1, 0], [1, 0]];
		for (var i = 0; i < 4; i++) {
			var d = document.createElement("div");
			d.className = "dir";
			place(d, ext + dirs[i][0] * R * 0.58, ext + dirs[i][1] * R * 0.58, R * 0.42);
			d.style.fontSize = (R * 0.36) + "px";
			d.textContent = arrows[i];
			dpadEl.appendChild(d);
			dirEls.push(d);
			keyByCode[pad.dpad[i].kc] = pad.dpad[i];
		}

		btnEl = document.createElement("div");
		btnEl.className = "pad";
		btnEl.style.width = btnEl.style.height = (ext * 2) + "px";
		btnEl.style.opacity = op;
		var pos = [[0, 1], [1, 0], [-1, 0], [0, -1]]; // bottom, right, left, top — as in the app
		for (var j = 0; j < 4; j++) {
			var b = pad.buttons[j];
			if (!b) continue;
			var e = document.createElement("div");
			e.className = "btn";
			place(e, ext + pos[j][0] * BD, ext + pos[j][1] * BD, BR);
			e.style.fontSize = (15 * sc) + "px";
			e.textContent = b.label;
			btnEl.appendChild(e);
			btnEls.push({ el: e, k: b, x: ext + pos[j][0] * BD, y: ext + pos[j][1] * BD });
			keyByCode[b.kc] = b;
		}
		dpadEl.ext = btnEl.ext = ext;
		document.body.appendChild(dpadEl);
		document.body.appendChild(btnEl);
		[dpadEl, btnEl].forEach(function (el) {
			el.addEventListener("pointerdown", onDown);
			el.addEventListener("pointermove", onMove);
			el.addEventListener("pointerup", onUp);
			el.addEventListener("pointercancel", onUp);
			el.addEventListener("lostpointercapture", onUp);
			el.addEventListener("contextmenu", function (ev) { ev.preventDefault(); });
		});
		layoutPad();
		showPad(padShown);
	}

	function place(el, cx, cy, r) {
		el.style.left = (cx - r) + "px";
		el.style.top = (cy - r) + "px";
		el.style.width = el.style.height = (r * 2) + "px";
	}

	function layoutPad() {
		if (!dpadEl) return;
		var ext = dpadEl.ext, margin = 20, reach = Math.max(R, BD + BR);
		var w = window.innerWidth, h = window.innerHeight;
		var leftX = margin + reach, rightX = w - margin - reach, cy = h - margin - reach;
		var dx = pad.swap ? rightX : leftX, bx = pad.swap ? leftX : rightX;
		dpadEl.style.left = (dx - ext) + "px"; dpadEl.style.top = (cy - ext) + "px";
		btnEl.style.left = (bx - ext) + "px"; btnEl.style.top = (cy - ext) + "px";
	}

	function showPad(on) {
		padShown = on;
		if (!dpadEl) return;
		releaseAll();
		dpadEl.style.display = btnEl.style.display = on ? "block" : "none";
	}

	function onDown(ev) {
		ev.preventDefault();
		ev.stopPropagation();
		activity();
		try { ev.currentTarget.setPointerCapture(ev.pointerId); } catch (e) {}
		origins[ev.pointerId] = ev.currentTarget === dpadEl ? "dpad" : "btn";
		pointerAt(ev);
	}
	function onMove(ev) {
		if (!(ev.pointerId in origins)) return;
		ev.preventDefault();
		pointerAt(ev);
	}
	function onUp(ev) {
		if (!(ev.pointerId in origins)) return;
		var old = pointers[ev.pointerId] || [];
		delete pointers[ev.pointerId];
		delete origins[ev.pointerId];
		apply(old, []);
	}

	function pointerAt(ev) {
		var codes = codesAt(ev.clientX, ev.clientY, origins[ev.pointerId]);
		var old = pointers[ev.pointerId] || [];
		pointers[ev.pointerId] = codes;
		apply(old, codes);
	}

	function codesAt(x, y, origin) {
		var res = [];
		if (origin === "dpad") {
			var r = dpadEl.getBoundingClientRect();
			var px = x - (r.left + dpadEl.ext), py = y - (r.top + dpadEl.ext);
			var dist = Math.sqrt(px * px + py * py);
			if (dist < R * 0.22 || dist > R * 2.5) return res;
			var t = R * 0.38;
			if (py < -t) res.push(pad.dpad[0].kc);
			if (py > t) res.push(pad.dpad[1].kc);
			if (px < -t) res.push(pad.dpad[2].kc);
			if (px > t) res.push(pad.dpad[3].kc);
			if (!res.length) {
				if (Math.abs(px) > Math.abs(py)) res.push(px < 0 ? pad.dpad[2].kc : pad.dpad[3].kc);
				else res.push(py < 0 ? pad.dpad[0].kc : pad.dpad[1].kc);
			}
			return res;
		}
		var br = btnEl.getBoundingClientRect(), best = null, bestD = 1e9;
		btnEls.forEach(function (b) {
			var dx = x - (br.left + b.x), dy = y - (br.top + b.y), d = Math.sqrt(dx * dx + dy * dy);
			if (d < bestD) { bestD = d; best = b; }
		});
		if (best && bestD <= BR * 1.35) res.push(best.k.kc);
		return res;
	}

	function apply(old, now) {
		var changed = false;
		old.forEach(function (c) {
			if (now.indexOf(c) < 0) {
				held[c] = (held[c] || 1) - 1;
				if (held[c] <= 0) { delete held[c]; stopRepeat(c); sendKey(keyByCode[c], false); }
				changed = true;
			}
		});
		now.forEach(function (c) {
			if (old.indexOf(c) < 0) {
				held[c] = (held[c] || 0) + 1;
				if (held[c] === 1) { sendKey(keyByCode[c], true); startRepeat(keyByCode[c]); }
				changed = true;
			}
		});
		if (changed) redraw();
	}

	function releaseAll() {
		Object.keys(held).forEach(function (c) {
			stopRepeat(c);
			if (held[c] > 0 && keyByCode[c]) sendKey(keyByCode[c], false);
		});
		held = {}; pointers = {}; origins = {};
		redraw();
	}

	function redraw() {
		if (!pad) return;
		for (var i = 0; i < dirEls.length; i++) dirEls[i].classList.toggle("on", held[pad.dpad[i].kc] > 0);
		btnEls.forEach(function (b) { b.el.classList.toggle("on", held[b.k.kc] > 0); });
	}

	// ---------------------------------------------------------------- pause button / menu
	var pauseBtn = document.getElementById("pauseBtn");
	var menu = document.getElementById("menu");
	var idleTimer = 0;

	function activity() {
		pauseBtn.classList.remove("idle");
		clearTimeout(idleTimer);
		idleTimer = setTimeout(function () { pauseBtn.classList.add("idle"); }, 5000);
	}

	function setPaused(on) {
		if (on === paused) return;
		paused = on;
		releaseAll();
		if (on) {
			document.getElementById("menuName").textContent = cfg.name || "";
			var mPad = document.getElementById("mPad");
			mPad.style.display = pad && pad.available ? "" : "none";
			mPad.textContent = padShown ? "Hide gamepad" : "Show gamepad";
			document.getElementById("mRenderer").textContent = "Renderer: " + rendererName(renderer());
			menu.classList.add("open");
			try { api && api.suspend && api.suspend(); } catch (e) {}
			audioOff(false);
		} else {
			menu.classList.remove("open");
			try { api && api.resume && api.resume(); } catch (e) {}
			audioOn();
			focusGame();
			activity();
		}
	}

	function stopEv(ev) { ev.stopPropagation(); }
	pauseBtn.addEventListener("pointerdown", stopEv);
	pauseBtn.addEventListener("click", function (ev) {
		ev.stopPropagation();
		if (pauseBtn.classList.contains("idle")) { activity(); return; }
		setPaused(true);
	});
	menu.addEventListener("pointerdown", stopEv);
	document.getElementById("mCont").onclick = function () { setPaused(false); };
	document.getElementById("mExit").onclick = function () { exit(); };
	document.getElementById("mRestart").onclick = function () {
		releaseAll();
		location.reload();
	};
	document.getElementById("mRenderer").onclick = function () {
		var i = RENDERERS.indexOf(renderer());
		setRenderer(RENDERERS[(i + 1) % RENDERERS.length]);
		releaseAll();
		location.reload();
	};
	document.getElementById("failExit").onclick = function () { exit(); };
	document.getElementById("failFallback").onclick = function () {
		tell("fallback");
		exit();
	};
	document.getElementById("failRenderer").onclick = function () {
		var i = RENDERERS.indexOf(renderer());
		setRenderer(RENDERERS[(i + 1) % RENDERERS.length]);
		location.reload();
	};
	document.getElementById("mPad").onclick = function () {
		showPad(!padShown);
		tell("pad", padShown ? "1" : "0");
		setPaused(false);
	};

	/** stop the game for good: no sound, no player */
	var killed = false;
	function kill() {
		if (killed) return;
		killed = true;
		releaseAll();
		try { api && api.suspend && api.suspend(); } catch (e) {}
		audioOff(true);
		try { api && api.destroy && api.destroy(); } catch (e) {}
		try { if (player && player.parentNode) player.parentNode.removeChild(player); } catch (e) {}
	}

	/**
	 * Links. Ruffle asks window.confirm("... <url>") before opening one; we answer:
	 * - a page of the game's own site (a relative link: arcade versions send the player's page to
	 *   index.php after "submitting score", the site saves it and shows the game again): we have
	 *   no site, so the game starts over;
	 * - anything else (ads, "more games"): not opened.
	 */
	var leaving = false;
	function watchLeaving() {
		var realConfirm = window.confirm;
		window.confirm = function (msg) {
			var m = /(https?:\/\/[^\s"'<>]+)/.exec(String(msg || ""));
			if (!m) return realConfirm ? realConfirm.call(window, msg) : false;
			var host = "";
			try { host = new URL(m[1]).host; } catch (e) {}
			if (host === location.host && !leaving) {
				leaving = true;
				tell("navigated", m[1]);
				toast("The game wanted to open a web page; starting it over");
				setTimeout(function () { releaseAll(); location.reload(); }, 1500);
			}
			return false;
		};
	}

	function exit() {
		kill();
		if (app) app.exit(); else history.back();
	}

	var toastTimer = 0;
	function toast(msg) {
		var t = document.getElementById("toast");
		t.textContent = msg;
		t.style.display = "block";
		clearTimeout(toastTimer);
		toastTimer = setTimeout(function () { t.style.display = "none"; }, 3000);
	}

	// called by the app
	window.bw = {
		back: function () { if (failed) exit(); else setPaused(!paused); },
		pause: function () { if (!paused) setPaused(true); },
		resume: function () { if (!paused && !killed) { try { api && api.resume && api.resume(); } catch (e) {} audioOn(); } },
		sleep: function () { releaseAll(); try { api && api.suspend && api.suspend(); } catch (e) {} audioOff(false); },
		kill: kill,
		key: function (down, k) { sendKey(k, !!down); }
	};

	window.addEventListener("resize", layoutPad);
	document.addEventListener("pointerdown", function () { activity(); }, true);

	buildPad();
	activity();
	rufflePlayer();
})();
