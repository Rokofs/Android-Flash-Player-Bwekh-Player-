package fp
{
	import flash.display.Bitmap;
	import flash.display.BitmapData;
	import flash.display.DisplayObject;
	import flash.display.DisplayObjectContainer;
	import flash.display.InteractiveObject;
	import flash.display.Loader;
	import flash.display.LoaderInfo;
	import flash.display.MovieClip;
	import flash.display.Shape;
	import flash.display.Sprite;
	import flash.display.Stage;
	import flash.display.StageAlign;
	import flash.display.StageDisplayState;
	import flash.display.StageAspectRatio;
	import flash.display.StageQuality;
	import flash.display.StageScaleMode;
	import flash.events.ErrorEvent;
	import flash.events.Event;
	import flash.events.TextEvent;
	import flash.events.FocusEvent;
	import flash.events.IOErrorEvent;
	import flash.events.KeyboardEvent;
	import flash.events.MouseEvent;
	import flash.events.TouchEvent;
	import flash.events.UncaughtErrorEvent;
	import flash.events.SecurityErrorEvent;
	import flash.text.TextField;
	import flash.filesystem.File;
	import flash.filesystem.FileMode;
	import flash.filesystem.FileStream;
	import flash.geom.Matrix;
	import flash.geom.Point;
	import flash.geom.Rectangle;
	import flash.media.SoundMixer;
	import flash.utils.Timer;
	import flash.events.TimerEvent;
	import flash.media.SoundTransform;
	import flash.system.ApplicationDomain;
	import flash.system.Capabilities;
	import flash.system.System;
	import flash.system.LoaderContext;
	import flash.utils.ByteArray;
	import flash.utils.Endian;
	import flash.utils.getTimer;
	import flash.utils.setTimeout;

	import fp.avm1.Vm;
	import fp.avm1.VmLib;
	import fp.avm1.SoftMixer;
	import fp.ui.Gamepad;
	import fp.ui.Icons;
	import fp.ui.M;
	import fp.ui.PauseMenu;

	/**
	 * Full-screen landscape player.
	 *  ActionScript 3 files run in AIR itself (Loader.loadBytes). AIR for Android has no AVM1,
	 *  so ActionScript 1/2 files can't be played (Main refuses them before opening the player).
	 * Dispatches Event.CLOSE when the user exits.
	 */
	public class PlayerScreen extends Sprite
	{
		private var item:LibraryItem;
		private var settings:Settings;
		private var lib:Library;
		private var snack:Function;
		/** ():Object {l,t,r,b} — system bars / cutout over the screen */
		public var insetsFn:Function;

		private var bg:Shape;
		private var holder:Sprite;      // AIR content, scaled
		private var holderBg:Shape;
		private var loader:Loader;
		private var gamepad:Gamepad;
		/** the phone's keyboard for the game (see SoftKeys) */
		private var softKeys:SoftKeys;
		/** gamepad wanted for this file (settings + auto-detect + per-file choice) */
		private var padOn:Boolean = true;

		private var pauseBtn:Sprite;
		private var menu:PauseMenu;

		private var cw:Number = 550;    // content size in its own pixels
		private var ch:Number = 400;
		private var fps:Number = 24;
		private var contentRect:Rectangle = new Rectangle();

		// lower render resolution (Settings.renderRes): the Android surface the app draws on is
		// made smaller and the display hardware stretches it to the screen (NativeBridge)
		private var renderScale:Number = 1;
		/** times the render resolution waited for the screen to turn */
		private var renderWaits:int = 0;
		private var renderTried:Boolean = false;
		private var fullW:Number = 0;
		/** stage size the smaller surface was set up for */
		private var scaledW:Number = 0;
		/** getTimer() when to set up the smaller surface (0 = nothing planned) */
		private var renderDue:int = 0;
		private var scaledH:Number = 0;
		private var touchChecked:Boolean = false;

		private var paused:Boolean = false;
		private var savedRate:Number = 24;
		private var lastActivity:int = 0;
		/** stage size at the last layout: rotation doesn't always send a resize event */
		private var laidW:Number = -1;
		private var laidH:Number = -1;
		private var btnAlpha:Number = 1;

		private var lastFocus:InteractiveObject;
		private var dispatching:Boolean = false;
		private var lastErrorTime:int = -100000;

		private var wantThumb:Boolean = false;
		private var thumbFrames:int = 0;
		private var closed:Boolean = false;
		private var startedAt:int = 0;

		// AIR load diagnostics
		private var airStartTime:int = 0;
		private var airInited:Boolean = false;
		private var blankChecked:Boolean = false;
		private var status:TextField;
		private var statusUntil:int = 0;
		/** already tried the SWF packed inside this one (see SwfUnpack) */
		private var triedInner:Boolean = false;
		/** second start of an AS3 game that needs the stage in its main class's constructor (#1009) */
		/** 0: normal; 3: the main class's constructor reads the player's stage (SoPatch) */
		private var stageFix:int = 0;
		/** false on a PC (tools/desktop): no full screen to keep */
		private static const ON_PHONE:Boolean = Capabilities.manufacturer.indexOf("Android") >= 0;
		private var waitLogAt:int = 0;
		private var innerBytes:ByteArray;

		public function PlayerScreen(item:LibraryItem, settings:Settings, lib:Library, snack:Function)
		{
			this.item = item;
			this.settings = settings;
			this.lib = lib;
			this.snack = snack;

			var info:Object = item.info || {};
			if (info.w > 0 && info.h > 0)
			{
				cw = info.w;
				ch = info.h;
			}
			fps = info.fps > 0 ? info.fps : 24;

			bg = new Shape();
			addChild(bg);

			holder = new Sprite();
			holderBg = new Shape();
			holder.addChild(holderBg);
			addChild(holder);
			holder.addEventListener(FocusEvent.FOCUS_IN, onContentFocus);

			// AS1/AS2 scripts don't run here (see SwfConvert), so their keys can't work either
			// no keys in the code (an animation): no gamepad unless chosen for the file
			padOn = settings.padFor(item.name, info.keys);
			softKeys = new SoftKeys(this, function(code:int, ch:int, down:Boolean, shift:Boolean):void {
				sendKey(code, ch, down, shift);
			}, function():void {
				// the keyboard is gone: the game's focus back (its keys)
				var g:InteractiveObject = (lastFocus && lastFocus.stage) ? lastFocus : contentRoot as InteractiveObject;
				if (g && !closed) try { stage.focus = g; } catch (fe:Error) {}
			});
			softKeys.isGame = function(d:DisplayObject):Boolean { return isInContent(d); };
			gamepad = new Gamepad(settings, onPad);
			gamepad.visible = padOn;
			addChild(gamepad);

			pauseBtn = new Sprite();
			var s:Number = M.px(48);
			pauseBtn.graphics.beginFill(0x000000, 0.4);
			pauseBtn.graphics.drawCircle(s / 2, s / 2, s / 2);
			pauseBtn.graphics.endFill();
			var ic:Shape = Icons.shape("pause", M.px(28), 0xFFFFFF);
			ic.x = ic.y = (s - M.px(28)) / 2;
			pauseBtn.addChild(ic);
			pauseBtn.mouseChildren = false;
			pauseBtn.buttonMode = true;
			pauseBtn.addEventListener(MouseEvent.CLICK, function(e:MouseEvent):void {
				e.stopPropagation();
				if (pauseBtn.alpha > 0.15) setPaused(true);
			});
			for each (var t:String in [MouseEvent.MOUSE_DOWN, MouseEvent.MOUSE_UP, TouchEvent.TOUCH_BEGIN, TouchEvent.TOUCH_END])
				pauseBtn.addEventListener(t, function(e:Event):void { e.stopPropagation(); });
			addChild(pauseBtn);

			menu = new PauseMenu();
			menu.addEventListener(PauseMenu.CONTINUE, function(e:Event):void { setPaused(false); });
			menu.addEventListener(PauseMenu.EXIT, function(e:Event):void { close(); });
			menu.addEventListener(PauseMenu.RESTART, function(e:Event):void { restart(); });
			menu.addEventListener(PauseMenu.SEEK, onSeek);
			menu.addEventListener(PauseMenu.GAMEPAD, onTogglePad);
			menu.addEventListener(PauseMenu.KEYBOARD, function(e:Event):void {
				setPaused(false);
				// text of the game being typed in: the keyboard on it; otherwise the game's keys
				if (!(lastFocus && lastFocus.stage && softKeys.userOpen(lastFocus))) softKeys.open();
			});
			addChild(menu);

			addEventListener(Event.ADDED_TO_STAGE, onAdded);
		}

		// =================================================================== lifecycle

		private function onAdded(e:Event):void
		{
			removeEventListener(Event.ADDED_TO_STAGE, onAdded);
			stage.addEventListener(Event.RESIZE, onResize);
			stage.addEventListener(MouseEvent.MOUSE_DOWN, onActivity, true, 100);
			stage.addEventListener(TouchEvent.TOUCH_BEGIN, onActivity, true, 100);
			addEventListener(Event.ENTER_FRAME, onFrame);
			// some phones miss the switch to landscape when a game follows another one right away
			// (the screen ends up half portrait, half landscape): check and ask again
			for each (var ms:int in [400, 1400, 3000, 5000])
			{
				var oc:Timer = new Timer(ms, 1);
				oc.addEventListener(TimerEvent.TIMER, checkOrientation);
				oc.start();
			}
			wantThumb = !item.temporary && !lib.hasThumb(item);
			lastActivity = getTimer();
			startedAt = getTimer();
			Log.write("player: added to stage, " + stage.stageWidth + "x" + stage.stageHeight +
				", file=" + item.name +
				", info=" + JSON.stringify(item.info));
			Log.flush();
			try
			{
				layout();
			}
			catch (err:Error)
			{
				Log.error("player.layout", err);
			}
			try
			{
				startAir();
			}
			catch (err2:Error)
			{
				Log.error("player.start", err2);
			}
		}

		public function close():void
		{
			if (closed) return;
			closed = true;
			Log.write("player: close");
			gamepad.releaseAll();
			if (softKeys) softKeys.close();
			removeEventListener(Event.ENTER_FRAME, onFrame);
			resetRenderScale();
			if (stage)
			{
				stage.removeEventListener(Event.RESIZE, onResize);
				stage.removeEventListener(MouseEvent.MOUSE_DOWN, onActivity, true);
				stage.removeEventListener(TouchEvent.TOUCH_BEGIN, onActivity, true);
				if (paused) stage.frameRate = savedRate;
			}
			// silence first: sounds of a movie that is already unloaded may be out of reach
			AudioFlush.stopAll();
			unloadAir();
			// every sound of an AVM1 game (its mixers and channels), also what started while closing
			try { Log.write("player: sounds left after closing: " + VmLib.silenceAll()); } catch (ve:Error) {}
			// the menu is silent: a game AIR is still starting (loadBytes in progress), or one that
			// AIR couldn't stop, must not be heard there; startAir turns the sound back on
			// (not quite 0: what still plays in the menu shows in computeSpectrum, yet can't be heard)
			SoundMixer.soundTransform = new SoundTransform(0.001);
			// stop everything, then leave the output playing silence for a moment (AudioFlush)
			AudioFlush.run();
			Log.write("player: sound output kept busy (silence restarted " + AudioFlush.restarts + " times)");
			// (the log says whether AIR still outputs anything in the menu, and what silences it)
			var st0:Stage = stage;
			var gen:int = starts;
			var steps:Array = [
				[700, function():String { return "in the menu"; }],
				[1300, function():String { var n:int = stopAllClips(st0); return "after stopping " + n + " movie clips left on the stage"; }],
				[2100, function():String { System.gc(); System.gc(); return "after a garbage collection"; }],
				[3200, function():String { return "a second later"; }]
			];
			for each (var stp:Array in steps) setTimeout(function(at:int, f:Function):void {
				if (starts != gen) return; // a game runs again
				var what:String = f();
				setTimeout(function():void {
					if (starts != gen) return;
					Log.write("player: sound " + what + ": " + soundPeak());
				}, 400);
			}, stp[0], stp[0], stp[1]);
			dispatchEvent(new Event(Event.CLOSE));
		}

		/** stop every movie clip under d (the player's own included: it is only used in the menu) */
		private static function stopAllClips(d:DisplayObject):int
		{
			var n:int = 0;
			if (d is MovieClip) { try { MovieClip(d).stop(); n++; } catch (e:Error) {} }
			var c:DisplayObjectContainer = d as DisplayObjectContainer;
			if (c) for (var i:int = 0; i < c.numChildren; i++) try { n += stopAllClips(c.getChildAt(i)); } catch (e2:Error) {}
			return n;
		}

		/** what all of AIR's sound adds up to right now (0: silence) */
		public static function soundPeak(mixer:Object = null):String
		{
			try
			{
				var ba:ByteArray = new ByteArray();
				(mixer || SoundMixer).computeSpectrum(ba, false, 0);
				ba.position = 0;
				var peak:Number = 0;
				while (ba.bytesAvailable >= 4)
				{
					var v:Number = Math.abs(ba.readFloat());
					if (v > peak) peak = v;
				}
				return "peak " + (peak > 0 && peak < 0.001 ? peak.toExponential(2) : peak.toFixed(3));
			}
			catch (e:Error)
			{
				return "can't measure (" + e.message + ")";
			}
			return "";
		}

		private function restart():void
		{
			setPaused(false);
			unloadAir();
			startAir();
		}

		/**
		 * The game opened another page of its site in its own window (an arcade game sending its
		 * score). The site would show the game again, so: start it over (after the code that asked).
		 */
		private var navigating:Boolean = false;

		private function onGameNavigate(url:String, target:String):void
		{
			if (navigating) return;
			navigating = true;
			Log.write("player: the game opens " + url.substr(0, 80) + ": starting it over");
			setTimeout(function():void {
				navigating = false;
				if (!stage || !vm) return;
				snack("The game wanted to open a web page; started it over");
				restart();
			}, 1500);
		}

		/** Android back button. */
		public function onBack():void
		{
			setPaused(!paused);
		}

		/** App went to background. */
		/** back in the app: Android may have rotated the screen meanwhile — check it again */
		public function onActivate():void
		{
			orientFix = 0;
			for each (var ms:int in [400, 1400, 3000])
			{
				var oc:Timer = new Timer(ms, 1);
				oc.addEventListener(TimerEvent.TIMER, checkOrientation);
				oc.start();
			}
		}

		public function onDeactivate():void
		{
			Log.write("player: app deactivated (" + (getTimer() - startedAt) + " ms after start)");
			flushSaves("background");
			// rotating to landscape / entering full screen can send a short deactivate — ignore it
			if (getTimer() - startedAt < 4000) return;
			if (!paused) setPaused(true);
		}

		// =================================================================== AIR (AS3)

		/** games started in this app run (the menu's sound check stops when the next one starts) */
		private static var starts:int = 0;

		private function startAir():void
		{
			starts++;
			if (closed) return;
			Log.write("player: AIR sound output before the start: " + soundPeak());
			// nothing of an earlier game may be heard in this one: whatever still plays (a game AIR
			// couldn't stop, a sound it started after it was closed) stops before the volume is back
			AudioFlush.stopAll();
			try { VmLib.silenceAll(); } catch (ve:Error) {}
			// (and the output gets silence, not the last game's last buffer: see AudioFlush)
			AudioFlush.silence(1500);
			SoundMixer.soundTransform = new SoundTransform(paused ? 0 : 1);
			// (the log says whether anything of an earlier game is still heard, before this one makes a sound)
			for each (var pms:int in [60, 160, 1000, 2000, 4000, 6000, 8000, 10000, 13000, 16000, 20000]) setTimeout(function(at:int):void {
				Log.write("player: AIR sound output " + at + " ms after the volume came back: " + soundPeak() + ", mixers " + SoftMixer.describe());
			}, pms, pms);
			// MochiCrypt-packed game: its preloader would be stopped by AIR (#3226) —
			// decrypt the real game ourselves and start it directly
			if (!innerBytes && !triedInner && item.info && item.info.packed)
			{
				triedInner = true;
				var inner:ByteArray = SwfUnpack.findInnerSwf(item.file);
				Log.write("player: packed file, inner SWF " + (inner ? inner.length + " bytes" : "not found"));
				if (inner) useInner(inner);
			}
			var bytes:ByteArray = new ByteArray();
			if (innerBytes)
			{
				bytes.writeBytes(innerBytes);
			}
			else try
			{
				var fs:FileStream = new FileStream();
				fs.open(item.file, FileMode.READ);
				fs.readBytes(bytes);
				fs.close();
			}
			catch (e:Error)
			{
				snack("Can't read the file: " + e.message);
				close();
				return;
			}
			var info:Object = item.info || {};
			// Flash CS5 TLF text: Adobe's RSL is gone, ours is loaded first (see TlfLibrary)
			if (!innerBytes && info.as3 !== false && !tlfChecked)
			{
				tlfChecked = true;
				try { tlfNeeded = TlfLibrary.needed(SwfBytes.decompress(bytes)); } catch (te:Error) { tlfNeeded = false; }
				if (tlfNeeded)
				{
					Log.write("player: the game loads TLF text from Adobe's server (gone): using ours");
					Log.flush();
					prepareLibDomain(true, function():void {
						if (closed) return;
						startAir();
						layout();
					});
					return;
				}
			}
			if (!innerBytes && info.as3 === false)
			{
				// ActionScript 1/2: AIR for Android has no AVM1. Rewrite it as an AS3 movie, and either
				// run its code with our AVM1 engine (also animations: their scripts and buttons work as in Flash).
				var useVm:Boolean = true; // Ruffle (when it can't run here) → AVM1
				try { legacy = SwfConvert.convert(bytes, useVm); } catch (ce:Error) { Log.error("convert", ce); legacy = null; }
				if (legacy && legacy.deobInfo) Log.write("player: " + legacy.deobInfo);
				if (Log.ENABLED && !ON_PHONE && legacy && legacy.data && legacy.deobInfo.indexOf("de-obfuscated") >= 0)
				{
					// test builds on the PC: the decoded file, to read it in FFDec
					var dumped:ByteArray = new ByteArray();
					dumped.endian = Endian.LITTLE_ENDIAN;
					dumped.writeUTFBytes("FWS");
					dumped.writeByte(Math.min(255, Math.max(1, int(info.ver) || 8)));
					dumped.writeUnsignedInt(legacy.data.source.length + 8);
					dumped.writeBytes(legacy.data.source);
					Log.dump("deob-" + item.name, dumped);
				}
				if (!legacy || !legacy.swf)
				{
					cantPlay("couldn't convert this old Flash file");
					return;
				}
				Log.write("player: AS1/AS2 file converted (" + (useVm ? "AVM1 engine" : "simple") + "): " + legacy.totalFrames + " frames, " +
					legacy.droppedScripts + " code blocks" + (useVm ? "" : ", timeline scripts kept on " + countKeys(legacy.scripts) + " frames") +
					(legacy.droppedStreams ? ", " + legacy.droppedStreams + " empty sound streams removed" : "") +
					(legacy.vmStreams ? ", " + legacy.vmStreams + " clip stream sounds via mixer" : "") +
					(legacy.movedSounds ? ", " + legacy.movedSounds + " timeline sounds via mixer" : ""));
				Log.flush();
				bytes = legacy.swf;
				if (useVm) applyGameKeys(legacy.keys);
			}
			if (!legacy)
			{
				// AS3 save games (SharedObject, browser cookies) go to this file's own folder
				try
				{
					var cur:File = File.applicationStorageDirectory.resolvePath("saves-as3/current.txt");
					cur.parent.createDirectory();
					var cs:FileStream = new FileStream();
					cs.open(cur, FileMode.WRITE);
					cs.writeUTFBytes(saveFolderName());
					cs.close();
					var t0:int = getTimer();
					if (stageFix) { Log.write("player: patching the main class (" + "stage in its constructor" + ")…"); Log.flush(); }
					// localToGlobal & co. in the game's own coordinates (see GameCoords)
					try
					{
						var gp:ByteArray = GameCoords.patch(bytes);
						if (gp) { bytes = gp; Log.write("player: the game's global coordinates, stage size and window: its own"); }
						if (GameCoords.usesNetStream) Log.write("player: the game plays video (NetStream): full render resolution");
					}
					catch (ge:Error) { Log.error("player.coords", ge); }
					var sp:ByteArray = SoPatch.patch(bytes, stageFix);
					Log.write("player: save games: " + (sp ? "on" : "game doesn't use them") + " (" + (getTimer() - t0) + " ms)");
					if (sp) bytes = sp;
					Log.flush();
				}
				catch (pe:Error)
				{
					Log.error("player.savePatch", pe);
				}
			}
			drawHolderBg(innerBytes && innerBg >= 0 ? uint(innerBg) : info.bg >= 0 ? uint(info.bg) : 0xFFFFFF);
			stage.frameRate = Math.min(120, Math.max(1, fps));
			applyQuality();

			loader = new Loader();
			// (the game's "global" coordinates are this one's: see tools/so-shim/bwekh/Protos.as)
			loader.name = "bwekhGameLoader";
			GameCoords.install();
			GameCoords.root = legacy ? null : loader;
			GameCoords.setStageSize(cw, ch);
			GameCoords.window = new FakeWindow(cw, ch, function():void {
				Log.write("player: the game closed its window: back to the list");
				close();
			});
			loader.contentLoaderInfo.addEventListener(Event.INIT, onAirInit);
			// how far a game with the stage fix got (bwekh.MovieClipBase / SpriteBase report it)
			// (untyped: the event comes from the game's own copies of the event classes — a typed
			// parameter fails to take it, and the line is lost)
			loader.contentLoaderInfo.sharedEvents.addEventListener("bwekh", function(te:*):void {
				Log.write("player: " + Object(te).text);
				Log.flush();
			});
			loader.contentLoaderInfo.addEventListener(IOErrorEvent.IO_ERROR, onAirIOError);
			loader.contentLoaderInfo.addEventListener(SecurityErrorEvent.SECURITY_ERROR, onAirLoadError);
			loader.contentLoaderInfo.addEventListener(ErrorEvent.ERROR, onAirLoadError);
			airInited = false;
			blankChecked = false;
			airStartTime = getTimer();
			showStatus("AIR: loading " + item.name + "…");
			loader.uncaughtErrorEvents.addEventListener(UncaughtErrorEvent.UNCAUGHT_ERROR, onAirError);
			holder.addChild(loader);
			if (!legacy) { mapStageCoords(true); guardStage(true); }
			try
			{
				// (a game that needs the stage in its constructor: a child of the bwekh domain)
				var ctx:LoaderContext = new LoaderContext(false, new ApplicationDomain((stageFix || tlfNeeded) && stageBridge ? stageBridge : null));
				ctx.allowCodeImport = true;
				if (tlfNeeded)
				{
					var off:ByteArray = TlfLibrary.offline(bytes);
					if (off) bytes = off;
				}
				loader.loadBytes(bytes, ctx);
			}
			catch (e2:Error)
			{
				cantPlay("AIR refused to load it (" + e2.message + ")");
				return;
			}
			layout();
		}

		/**
		 * Domain the game's domain is a child of: the bwekh classes (bwekh.StageHolder.stage set,
		 * see SoPatch.shimLibrary) and, for Flash CS5 games with TLF text, the Text Layout Framework.
		 */
		private var stageBridge:ApplicationDomain;
		private var bridgeLoaders:Array = [];
		private var libHasTlf:Boolean = false;
		/** the game loads TLF as an RSL from Adobe (see TlfLibrary) */
		private var tlfNeeded:Boolean = false;
		private var tlfChecked:Boolean = false;

		/**
		 * The game's patched constructor reads the stage from bwekh.appStage. On a PC that asks the
		 * app's window; Android has none (NativeWindow isn't supported there), so the stage is handed
		 * over through a domain the game's domain is a child of. The TLF library goes there too.
		 */
		/** loading the libraries before the game: the "AIR didn't load it" watchdog waits */
		private var preparingLibs:Boolean = false;

		private function prepareLibDomain(withTlf:Boolean, then:Function):void
		{
			if (stageBridge && (!withTlf || libHasTlf)) { then(); return; }
			preparingLibs = true;
			var t0:int = getTimer();
			var dom:ApplicationDomain = stageBridge ? stageBridge : new ApplicationDomain();
			var steps:Array = [];
			if (!stageBridge) steps.push({ name: "bwekh", bytes: SoPatch.shimLibrary() });
			if (withTlf && !libHasTlf) steps.push({ name: "tlf", bytes: TlfLibrary.bytes });
			var finished:Boolean = false;
			var next:Function = function():void {
				if (finished) return;
				if (closed) { finished = true; preparingLibs = false; return; }
				if (!steps.length)
				{
					finished = true;
					preparingLibs = false;
					Log.write("player: libraries ready (" + (getTimer() - t0) + " ms)");
					then();
					return;
				}
				var st:Object = steps.shift();
				var ld:Loader = new Loader();
				bridgeLoaders.push(ld);
				var stepDone:Boolean = false;
				var after:Function = function(ok:Boolean):void {
					if (stepDone) return;
					stepDone = true;
					if (ok && st.name == "bwekh")
					{
						try
						{
							dom.getDefinition("bwekh.StageHolder").stage = stage;
							stageBridge = dom;
							Log.write("player: stage handed over to the game's domain (" + (stage ? "ok" : "no stage") + ")");
						}
						catch (he:Error) { Log.error("player.stageBridge", he); }
					}
					if (ok && st.name == "tlf")
					{
						libHasTlf = true;
						stageBridge = dom;
						Log.write("player: Text Layout Framework 1.0 loaded for the game");
					}
					if (!ok) Log.write("player: couldn't load " + st.name + " for the game");
					next();
				};
				ld.contentLoaderInfo.addEventListener(Event.INIT, function(e:Event):void { after(true); });
				ld.contentLoaderInfo.addEventListener(IOErrorEvent.IO_ERROR, function(e:Event):void { after(false); });
				ld.contentLoaderInfo.addEventListener(ErrorEvent.ERROR, function(e:Event):void { after(false); });
				ld.uncaughtErrorEvents.addEventListener(UncaughtErrorEvent.UNCAUGHT_ERROR, function(e:UncaughtErrorEvent):void {
					Log.write("player: error in " + st.name + ": " + e.error);
					e.preventDefault();
				});
				try
				{
					var bctx:LoaderContext = new LoaderContext(false, dom);
					bctx.allowCodeImport = true;
					ld.loadBytes(st.bytes, bctx);
				}
				catch (le:Error)
				{
					Log.error("player.libDomain", le);
					after(false);
				}
				setTimeout(function():void {
					if (!stepDone) Log.write("player: " + st.name + ": no INIT in 15 s (loaded " + ld.contentLoaderInfo.bytesLoaded + "/" + ld.contentLoaderInfo.bytesTotal + ")");
					after(false);
				}, 15000); // never wait for ever
			};
			next();
		}

		// =================================================================== what AS3 games do to the stage

		private var guarding:Boolean = false;
		private var guardStageRef:Stage;
		private var fsGraceUntil:int = 0;
		private var winX:Number = NaN, winY:Number = NaN;
		private var guardLogged:Object = {};

		/**
		 * AS3 games made for a browser or a desktop AIR app change the stage the player shares:
		 * full screen off (FlashPunk: displayState = NORMAL), the window moved (nativeWindow.x = 100),
		 * their own objects put right on the stage. On the phone that moved the picture sideways
		 * (more at a lower render resolution) or drew the game outside the player.
		 */
		private function guardStage(on:Boolean):void
		{
			if (on == guarding) return;
			var st:Stage = on ? stage : guardStageRef;
			if (!st) return;
			guarding = on;
			guardStageRef = on ? st : null;
			if (on)
			{
				guardLogged = {};
				winX = winY = NaN;
				stageColor0 = st.color;
				try
				{
					var nw:Object = st["nativeWindow"];
					if (nw) { winX = nw.x; winY = nw.y; }
				}
				catch (e:Error) {}
				st.addEventListener(Event.ADDED, onStageAdded);
			}
			else
			{
				st.removeEventListener(Event.ADDED, onStageAdded);
				// the player's own background colour back (a game may have set stage.color)
				try { st.color = stageColor0; } catch (ce:Error) {}
			}
		}

		/** the stage colour before the game (put back when it closes) */
		private var stageColor0:uint = 0xF5F5F5;

		private function guardNote(key:String, text:String):void
		{
			if (guardLogged[key]) return;
			guardLogged[key] = true;
			Log.write("player: " + text);
		}

		private function checkStage():void
		{
			var st:Stage = guardStageRef;
			if (!st || closed) return;
			if (st.color != stageColor0 && st.color != holderColor)
			{
				// the game set stage.color: in Flash Player that's the colour around and behind
				// everything it draws — here the game's area shows it
				guardNote("color", "the game set the stage colour to 0x" + st.color.toString(16) + ": its background");
				drawHolderBg(st.color);
			}
			if (ON_PHONE && getTimer() > fsGraceUntil && st.displayState != StageDisplayState.FULL_SCREEN_INTERACTIVE)
			{
				guardNote("fs", "the game left full screen (" + st.displayState + "): back");
				try { st.displayState = StageDisplayState.FULL_SCREEN_INTERACTIVE; } catch (e:Error) {}
				fsGraceUntil = getTimer() + 1000;
				// leaving and entering full screen makes Android set up the surface again: a smaller
				// render surface set up before is gone or half there (an empty screen) — set it up
				// once more when the screen has settled
				if (renderScale < 1)
				{
					Log.write("player: render resolution again after the full screen change");
					resetRenderScale();
					renderTried = false;
					renderWaits = 0;
					renderDue = getTimer() + 1200;
				}
			}
			if (st.scaleMode != StageScaleMode.NO_SCALE || st.align != StageAlign.TOP_LEFT)
			{
				guardNote("scale", "the game changed the stage scale mode / align: back");
				st.scaleMode = StageScaleMode.NO_SCALE;
				st.align = StageAlign.TOP_LEFT;
			}
			if (!isNaN(winX))
			{
				try
				{
					var nw:Object = st["nativeWindow"];
					if (nw && (nw.x != winX || nw.y != winY))
					{
						guardNote("win", "the game moved the window to " + nw.x + "," + nw.y + ": back");
						nw.x = winX;
						nw.y = winY;
					}
				}
				catch (e2:Error) {}
			}
		}

		/** the game put something right on the stage: into the player, under its buttons */
		private function onStageAdded(e:Event):void
		{
			var d:DisplayObject = e.target as DisplayObject;
			var st:Stage = guardStageRef;
			if (!d || !st || d.parent != st || d == root || closed) return;
			guardNote("added", "the game put " + d + " on the stage: moved into the game's area");
			// into the game's own space (above the game, scaled and placed with it): the game's
			// stage coordinates and stage size are its own (see GameCoords), as in Flash Player
			try
			{
				if (loader && loader.parent == holder) holder.addChildAt(d, holder.getChildIndex(loader) + 1);
				else holder.addChild(d);
			}
			catch (err:Error) { Log.error("player.stageChild", err); }
		}

		// =================================================================== game coordinates

		private static const MAP_MOUSE:Array = [MouseEvent.MOUSE_MOVE, MouseEvent.MOUSE_DOWN, MouseEvent.MOUSE_UP,
			MouseEvent.CLICK, MouseEvent.DOUBLE_CLICK, MouseEvent.MOUSE_WHEEL];
		private static const MAP_TOUCH:Array = [TouchEvent.TOUCH_BEGIN, TouchEvent.TOUCH_MOVE, TouchEvent.TOUCH_END, TouchEvent.TOUCH_TAP];
		private var mapOn:Boolean = false;
		private var mapStage:Stage;
		private var mapRedispatch:Boolean = false;
		private var mapLogged:Boolean = false;

		/**
		 * An AS3 game shares AIR's stage with the player, but it is scaled into `holder`, so the
		 * stageX/stageY its stage listeners get are screen pixels, not its own stage coordinates
		 * as in Flash (Nyan Cat: steering Supernyan/Rocketnyan by moving the finger).
		 * Before the game's stage listeners run, the event's coordinates are moved into game space.
		 * Only stage listeners see this (they run last); the game's own objects got the event already.
		 */
		private function mapStageCoords(on:Boolean):void
		{
			if (on == mapOn) return;
			var st:Stage = on ? stage : mapStage;
			if (!st) return;
			mapOn = on;
			mapStage = on ? st : null;
			var t:String;
			for each (t in MAP_MOUSE)
				if (on) st.addEventListener(t, onMapMouse, false, int.MAX_VALUE);
				else st.removeEventListener(t, onMapMouse, false);
			for each (t in MAP_TOUCH)
				if (on) st.addEventListener(t, onMapTouch, false, int.MAX_VALUE);
				else st.removeEventListener(t, onMapTouch, false);
		}

		/** the point in game coordinates, or null when the event isn't about the game */
		private function gamePoint(target:Object, sx:Number, sy:Number):Point
		{
			if (!loader || closed) return null;
			var d:DisplayObject = target as DisplayObject;
			if (!d || (d != mapStage && !holder.contains(d))) return null;
			return loader.globalToLocal(new Point(sx, sy));
		}

		private function onMapMouse(e:MouseEvent):void
		{
			if (mapRedispatch) return;
			var g:Point = gamePoint(e.target, e.stageX, e.stageY);
			if (!g) return;
			var d:DisplayObject = DisplayObject(e.target);
			// MouseEvent.stageX is calculated from localX (relative to the target)
			var l:Point = d.globalToLocal(g);
			try { e.localX = l.x; e.localY = l.y; } catch (err:Error) {}
			if (Math.abs(e.stageX - g.x) < 0.5 && Math.abs(e.stageY - g.y) < 0.5)
			{
				if (!mapLogged) { mapLogged = true; Log.write("player: game coordinates for stage listeners: ok"); }
				return;
			}
			// this AIR doesn't recalculate stageX: send the game's stage listeners a copy aimed at the stage
			if (!mapLogged) { mapLogged = true; Log.write("player: game coordinates for stage listeners: copy"); }
			e.stopImmediatePropagation();
			var c:MouseEvent = new MouseEvent(e.type, false, e.cancelable, g.x, g.y, e.relatedObject,
				e.ctrlKey, e.altKey, e.shiftKey, e.buttonDown, e.delta);
			mapRedispatch = true;
			try { mapStage.dispatchEvent(c); } catch (err2:Error) {}
			mapRedispatch = false;
		}

		private function onMapTouch(e:TouchEvent):void
		{
			var g:Point = gamePoint(e.target, e.stageX, e.stageY);
			if (!g) return;
			var l:Point = DisplayObject(e.target).globalToLocal(g);
			try { e.localX = l.x; e.localY = l.y; } catch (err:Error) {}
		}

		/** folder under saves-as3 for this file's AS3 save games */
		private function saveFolderName():String
		{
			return item.name.replace(/[^A-Za-z0-9._-]+/g, "_");
		}

		/** write out the game's save data now (game closes, app goes to the background) */
		private function flushSaves(why:String):void
		{
			var n:* = null;
			try
			{
				if (loader && loader.contentLoaderInfo && loader.contentLoaderInfo.applicationDomain &&
					loader.contentLoaderInfo.applicationDomain.hasDefinition(SoPatch.CLASS_NAME))
				{
					var C:Object = loader.contentLoaderInfo.applicationDomain.getDefinition(SoPatch.CLASS_NAME);
					n = C.flushAll();
				}
			}
			catch (e:Error) { Log.error("player.flushSaves", e); }
			try { if (vm && vm.lib) n = vm.lib.flushAll(); } catch (e2:Error) { Log.error("player.flushSaves", e2); }
			if (n !== null) Log.write("player: save games written (" + why + "): " + n);
		}

		/**
		 * The game's own sounds, stopped from inside it: a loaded game has its own copies of the
		 * built-in classes (and its own sound sandbox), so the player's SoundMixer.stopAll() may not
		 * reach what it plays (a looping music kept playing in the next game). Its own
		 * SoundMixer.stopAll() does.
		 */
		/** the same, as the game's own SoundMixer sees it */
		private function gamePeak():String
		{
			try
			{
				var dom:ApplicationDomain = loader.contentLoaderInfo.applicationDomain;
				var gm:Object = dom && dom.hasDefinition("flash.media.SoundMixer") ? dom.getDefinition("flash.media.SoundMixer") : null;
				if (gm && gm != SoundMixer) return " (the game's: " + soundPeak(gm) + ")";
			}
			catch (e:Error) {}
			return "";
		}

		private function silenceGame():void
		{
			try
			{
				var inaccessible:Boolean = SoundMixer.areSoundsInaccessible();
				var dom:ApplicationDomain = loader.contentLoaderInfo.applicationDomain;
				var gm:Object = dom && dom.hasDefinition("flash.media.SoundMixer") ? dom.getDefinition("flash.media.SoundMixer") : null;
				if (gm && gm != SoundMixer) gm.stopAll();
				AudioFlush.keep(true);
				if (inaccessible || (gm && gm != SoundMixer)) Log.write("player: the game's sounds stopped from inside it" +
					(inaccessible ? " (the player can't reach them)" : "") + (gm != SoundMixer ? " (its own SoundMixer)" : ""));
			}
			catch (e:Error) { Log.write("player: the game's sounds: " + e.message); }
		}

		private function unloadAir():void
		{
			flushSaves("close");
			mapStageCoords(false);
			guardStage(false);
			stopVm();
			GameCoords.root = null;
			if (!loader) return;
			silenceGame();
			loader.contentLoaderInfo.removeEventListener(Event.INIT, onAirInit);
			loader.contentLoaderInfo.removeEventListener(IOErrorEvent.IO_ERROR, onAirIOError);
			loader.contentLoaderInfo.removeEventListener(SecurityErrorEvent.SECURITY_ERROR, onAirLoadError);
			loader.contentLoaderInfo.removeEventListener(ErrorEvent.ERROR, onAirLoadError);
			loader.uncaughtErrorEvents.removeEventListener(UncaughtErrorEvent.UNCAUGHT_ERROR, onAirError);
			try { loader.close(); } catch (e:Error) {}
			try { loader.unloadAndStop(true); } catch (e2:Error) {}
			if (!airInited)
			{
				// loadBytes can't be cancelled: when the content still arrives, stop it right away
				var late:Loader = loader;
				late.contentLoaderInfo.addEventListener(Event.INIT, function(le:Event):void {
					Log.write("player: a game still arrived after it was closed: stopped");
					try { late.unloadAndStop(true); } catch (e3:Error) {}
				});
			}
			if (loader.parent) loader.parent.removeChild(loader);
			loader = null;
			// what the game put on the stage (moved into its area) goes with it
			for (var hi:int = holder.numChildren - 1; hi >= 0; hi--)
			{
				var hc:DisplayObject = holder.getChildAt(hi);
				if (hc != holderBg) try { holder.removeChild(hc); } catch (he:Error) {}
			}
			lastFocus = null;
			if (stage)
			{
				stage.scaleMode = StageScaleMode.NO_SCALE;
				stage.align = StageAlign.TOP_LEFT;
			}
		}

		private function onAirInit(e:Event):void
		{
			airInited = true;
			if (renderDue > 0) renderDue = getTimer() + 800;
			Log.write("player: AIR INIT, content=" + contentRoot + ", stage=" + stage.stageWidth + "x" + stage.stageHeight + ", fps=" + stage.frameRate); Log.flush();
			try
			{
				Log.write("player: the game's helper code (bwekh.Protos): " +
					(loader.contentLoaderInfo.applicationDomain.hasDefinition("bwekh.Protos") ? "in" : "not found"));
			}
			catch (pe:Error) { Log.write("player: the game's helper code: can't look (" + pe.message + ")"); }
			var root0:DisplayObject = contentRoot;
			var frames:int = 0;
			try { frames = MovieClip(root0).totalFrames; } catch (fe:Error) {}
			showStatus("AIR: loaded (" + (root0 ? root0.toString() : "no content") +
				(frames > 0 ? ", " + frames + " frames" : "") + ")");
			var info:Object = item.info || {};
			if (!info.parsed)
			{
				try
				{
					cw = loader.contentLoaderInfo.width;
					ch = loader.contentLoaderInfo.height;
					fps = loader.contentLoaderInfo.frameRate;
					stage.frameRate = fps;
				}
				catch (err:Error) {}
				drawHolderBg(0xFFFFFF);
			}
			var cr:InteractiveObject = contentRoot as InteractiveObject;
			if (cr)
			{
				try { stage.focus = cr; } catch (err2:Error) {}
			}
			if (legacy && legacy.data)
			{
				startVm(contentRoot as MovieClip);
			}
			else if (legacy)
			{
				var applied:int = legacy.apply(contentRoot as MovieClip);
				Log.write("player: main timeline scripts on " + applied + " frames; buttons " + legacy.buttonCount + ", clips with scripts " + legacy.clipCount);
				legacy.hook(contentRoot as MovieClip);
			}
			thumbFrames = 0;
			layout();
		}

		private function onAirLoadError(e:ErrorEvent):void
		{
			e.preventDefault();
			cantPlay("AIR couldn't load it (" + e.text + ")");
		}

		/**
		 * AIR can't show this file. Many games are a small preloader that unpacks the real game
		 * with Loader.loadBytes, which AIR forbids (#3226) — try the SWF packed inside once.
		 */
		private function cantPlay(reason:String):void
		{
			if (closed) return;
			Log.write("player: can't play: " + reason);
			if (!triedInner)
			{
				triedInner = true;
				var inner:ByteArray = SwfUnpack.findInnerSwf(item.file);
				if (inner)
				{
					Log.write("player: trying the SWF packed inside (" + inner.length + " bytes)");
					showStatus("Loading the game packed inside the file…");
					useInner(inner);
					wantThumb = !item.temporary && !lib.hasThumb(item);
					unloadAir();
					startAir();
					layout();
					return;
				}
				Log.write("player: no SWF packed inside");
			}
			snack("Can't play " + item.name + ": " + reason);
			close();
		}

		/** Play this SWF (found inside the file) instead of the file itself. */
		private function useInner(inner:ByteArray):void
		{
			innerBytes = inner;
			var si:SwfInfo = SwfInfo.parse(inner);
			if (si.parsed && si.width > 0 && si.height > 0)
			{
				cw = si.width;
				ch = si.height;
				if (si.frameRate > 0) fps = si.frameRate;
			}
			innerBg = si.parsed ? si.bgColor : -1;
		}

		private var innerBg:int = -1;
		/** AS1/AS2 file rewritten for AIR (null for normal files) */
		private var legacy:SwfConvert;
		/** our ActionScript 1/2 engine (AVM1 mode) */
		private var vm:Vm;

		private function startVm(root:MovieClip):void
		{
			if (!root) return;
			try
			{
				Vm.compileCode = settings.avm1Compile;
				vm = new Vm(legacy.data, function(s:String):void { Log.write(s); });
				vm.lib.storage = { load: loadSave, save: storeSave };
				vm.lib.onNavigate = onGameNavigate;
				vm.lib.onQuit = function():void {
					Log.write("player: the game closed itself");
					setTimeout(function():void { if (stage) close(); }, 0);
				};
				vm.debug = Log.ENABLED; // detailed AVM1 log only in test builds
				if (Log.ENABLED)
				{
					// test builds: where the time goes, every 3 s (the game's code, our frame events, the rest = AIR)
					vm.measure = true;
					vm.display.timing = { enter: 0, walk: 0, frames: 0 };
					startPerfLog();
				}
				Log.write("player: AVM1 engine starting");
				Log.flush();
				vm.display.start(root);
				Log.write("player: AVM1 self-test: clip methods " + (vm.isFunc(vm.objGet(vm.clipProto, "gotoAndPlay")) ? "ok" : "MISSING"));
				Log.write("player: AVM1 engine started (SWF " + legacy.data.version + ", " +
					countKeys(legacy.data.frameActions) + " timelines with code, " + legacy.data.initActions.length + " #initclip)");
			}
			catch (e:Error)
			{
				Log.error("avm1.start", e);
			}
		}

		private var perfTimer:Timer;
		private var perfAt:int = 0;

		private function startPerfLog():void
		{
			if (perfTimer) perfTimer.stop();
			perfAt = getTimer();
			perfTimer = new Timer(3000);
			perfTimer.addEventListener(TimerEvent.TIMER, function(e:TimerEvent):void {
				if (!vm || !vm.display.timing) { perfTimer.stop(); return; }
				var now:int = getTimer();
				var secs:Number = Math.max(0.001, (now - perfAt) / 1000);
				var t:Object = vm.display.timing;
				Log.write("perf: " + (t.frames / secs).toFixed(1) + " fps, game code " + Math.round(vm.execMs / secs) +
					" ms/s, clip events " + Math.round(t.enter / secs) + " ms/s, timeline walk " + Math.round(t.walk / secs) +
					" ms/s, clips " + vm.display.clipCount + ", " + Math.round(vm.instrCount / secs) + " instructions/s, sound output " + soundPeak() + gamePeak());
				Log.write("perf: mixers " + SoftMixer.describe());
				if (vm.hcount) Log.write("perf: " + vm.hcountSummary());
				vm.hcount = {};
				vm.execMs = 0;
				vm.instrCount = 0;
				vm.display.timing = { enter: 0, walk: 0, frames: 0 };
				perfAt = now;
			});
			perfTimer.start();
		}

		private function stopVm():void
		{
			if (perfTimer) { perfTimer.stop(); perfTimer = null; }
			if (!vm) return;
			try { vm.display.dispose(); } catch (e:Error) {}
			vm = null;
		}

		/** SharedObject save games: app storage / saves / <file>/<name>.json */
		private function saveFile(name:String):File
		{
			var safe:String = (item.name + "_" + name).replace(/[^A-Za-z0-9._-]+/g, "_");
			return File.applicationStorageDirectory.resolvePath("saves/" + safe + ".json");
		}

		private function loadSave(name:String):String
		{
			try
			{
				var f:File = saveFile(name);
				if (!f.exists) return null;
				var fs:FileStream = new FileStream();
				fs.open(f, FileMode.READ);
				var s:String = fs.readUTFBytes(fs.bytesAvailable);
				fs.close();
				return s;
			}
			catch (e:Error) {}
			return null;
		}

		private function storeSave(name:String, json:String):void
		{
			try
			{
				var f:File = saveFile(name);
				f.parent.createDirectory();
				var fs:FileStream = new FileStream();
				fs.open(f, FileMode.WRITE);
				fs.writeUTFBytes(json);
				fs.close();
			}
			catch (e:Error)
			{
				Log.error("avm1.save", e);
			}
		}

		private static function countKeys(o:Object):int
		{
			var n:int = 0;
			for (var k:String in o) n++;
			return n;
		}

		private function showStatus(text:String, ms:int = 6000):void
		{
			if (!status)
			{
				status = M.text("", 12, 0xFFFFFF);
				status.background = true;
				status.backgroundColor = 0x000000;
				status.alpha = 0.7;
				addChild(status);
			}
			status.text = text;
			status.visible = true;
			statusUntil = getTimer() + ms;
			if (stage)
			{
				status.x = M.px(8);
				status.y = M.px(8);
				setChildIndex(status, numChildren - 1);
			}
		}

		private function onAirIOError(e:IOErrorEvent):void
		{
			e.preventDefault();
			cantPlay("AIR couldn't read it (" + e.text + ")");
		}

		private function onAirError(e:UncaughtErrorEvent):void
		{
			e.preventDefault();
			Log.error("swf", e.error);
			// #3226: a preloader that unpacks the real game with Loader.loadBytes — AIR forbids that
			var err:Error = e.error as Error;
			if (err && err.errorID == 3226 && !triedInner)
			{
				cantPlay("AIR blocked this file (security error #3226)");
				return;
			}
			// #1009 before the game even started: its main class uses "stage" in its constructor
			// (a browser has it there; a Loader adds the game later). Start it once more with the
			// stage handed over early (Inter Schminter comics: "stage.align = ...").
			if (err && err.errorID == 1009 && !airInited && stageFix == 0 && !legacy)
			{
				stageFix = 3;
				waitLogAt = 0;
				Log.write("player: #1009 at start: once more, with the stage given to the game's constructor");
				Log.flush();
				setTimeout(function():void {
					if (closed || airInited) return;
					unloadAir();
					prepareLibDomain(tlfNeeded, function():void {
						if (closed || airInited) return;
						startAir();
						layout();
					});
				}, 0);
				return;
			}
			var now:int = getTimer();
			if (now - lastErrorTime < 6000) return;
			lastErrorTime = now;
			var msg:String = e.error is Error ? (e.error as Error).message
				: e.error is ErrorEvent ? ErrorEvent(e.error).text : String(e.error);
			if (msg.length > 120) msg = msg.substr(0, 120) + "…";
			// (only in the log: error messages on the screen are no use to the player)
			Log.write("player: error in the SWF: " + msg);
		}

		private function get contentRoot():DisplayObject
		{
			try { return loader ? loader.content : null; } catch (e:Error) {}
			return null;
		}

		/** colour of the game's area now */
		private var holderColor:uint = 0xFFFFFF;

		private function drawHolderBg(color:uint):void
		{
			holderColor = color;
			holderBg.graphics.clear();
			holderBg.graphics.beginFill(color);
			holderBg.graphics.drawRect(0, 0, cw, ch);
			holderBg.graphics.endFill();
		}

		private function onContentFocus(e:FocusEvent):void
		{
			var io:InteractiveObject = e.target as InteractiveObject;
			if (io && isInContent(io))
			{
				lastFocus = io;
				// text to type in: the phone's keyboard (see SoftKeys)
				if (ON_PHONE && softKeys) softKeys.gameFocus(io);
			}
		}

		private function isInContent(d:DisplayObject):Boolean
		{
			try
			{
				while (d)
				{
					if (d == loader) return true;
					d = d.parent;
				}
			}
			catch (e:Error) {}
			return false;
		}

		private function applyQuality():void
		{
			var q:String = StageQuality.HIGH;
			switch (settings.quality)
			{
				case "low": q = StageQuality.LOW; break;
				case "medium": q = StageQuality.MEDIUM; break;
				case "best": q = StageQuality.BEST; break;
			}
			try { stage.quality = q; } catch (e:Error) {}
		}

		// =================================================================== keys from the gamepad

		private var padLogged:int = 0;

		private function onPad(code:int, down:Boolean):void
		{
			if (paused) return;
			onActivity(null);
			var k:Object = Keys.byCode(code);
			if (!k) return;
			if (padLogged < 6)
			{
				padLogged++;
				Log.write("pad: " + code + (down ? " down" : " up"));
			}
			sendKey(code, k.ch, down, code == 16, k.loc, softKeys && softKeys.active, code == 17, code == 18);
		}

		/**
		 * A key press to the game, as from a keyboard. keepFocus: don't move the focus to the game
		 * (the phone's keyboard is typing into our own field, see SoftKeys).
		 */
		private function sendKey(code:int, ch:int, down:Boolean, shift:Boolean, loc:int = 0, keepFocus:Boolean = true,
			ctrl:Boolean = false, alt:Boolean = false):void
		{
			if (!loader || paused) return;
			var type:String = down ? KeyboardEvent.KEY_DOWN : KeyboardEvent.KEY_UP;
			var ev:KeyboardEvent = new KeyboardEvent(type, true, false, ch, code, loc, ctrl, alt, shift);
			var target:InteractiveObject = null;
			var f:InteractiveObject = stage.focus;
			if (f && isInContent(f)) target = f;
			else if (lastFocus && lastFocus.stage && isInContent(lastFocus)) target = lastFocus;
			else target = contentRoot as InteractiveObject;
			if (target && stage.focus != target && !keepFocus)
			{
				try { stage.focus = target; } catch (e:Error) {}
			}
			dispatching = true;
			try
			{
				if (target) target.dispatchEvent(ev);
				else stage.dispatchEvent(ev);
			}
			catch (err:Error)
			{
			}
			dispatching = false;
		}

		public function get isDispatchingVirtualKey():Boolean
		{
			return dispatching;
		}

		// =================================================================== pause / seek

		private function setPaused(value:Boolean):void
		{
			if (value == paused || closed) return;
			paused = value;
			Log.write("player: paused=" + value);
			if (vm) vm.display.paused = value;
			gamepad.releaseAll();
			if (paused)
			{
				var frame:int = 1, frames:int = 1;
				var seekable:Boolean = false;
				var mc:MovieClip = contentRoot as MovieClip;
				if (mc)
				{
					try
					{
						frame = mc.currentFrame;
						frames = mc.totalFrames;
						seekable = frames > 1;
					}
					catch (e:Error) {}
				}
				else if (item.info)
				{
					frames = item.info.frames;
				}
				if (softKeys) softKeys.close();
				menu.open(item.name, frame, frames, fps, seekable, item.duration,
					settings.gamepadEnabled ? (padOn ? 1 : 0) : -1, ON_PHONE);
				layout();
				{
					// don't drop the frame rate to ~0: that freezes our own menu too
					// (and after a background/foreground switch the screen may never redraw)
					savedRate = stage.frameRate;
					stopTimelines();
					SoundMixer.soundTransform = new SoundTransform(0);
					stage.frameRate = 10;
				}
			}
			else
			{
				menu.visible = false;
				{
					stage.frameRate = savedRate;
					resumeTimelines();
					SoundMixer.soundTransform = new SoundTransform(1);
					var cr:InteractiveObject = (lastFocus && lastFocus.stage) ? lastFocus : contentRoot as InteractiveObject;
					if (cr)
					{
						try { stage.focus = cr; } catch (e2:Error) {}
					}
				}
				onActivity(null);
			}
		}

		private var stoppedClips:Array = [];

		/** Stop every playing timeline in the content (remember which ones to restart). */
		private function stopTimelines():void
		{
			stoppedClips = [];
			var root0:DisplayObjectContainer = contentRoot as DisplayObjectContainer;
			if (root0) walkStop(root0, 0);
		}

		private function walkStop(d:DisplayObjectContainer, depth:int):void
		{
			if (depth > 40) return;
			var mc:MovieClip = d as MovieClip;
			if (mc && mc.totalFrames > 1)
			{
				var playing:Boolean = false;
				try { playing = mc["isPlaying"]; } catch (e:Error) { playing = false; }
				if (playing)
				{
					mc.stop();
					stoppedClips.push(mc);
				}
			}
			var n:int = 0;
			try { n = d.numChildren; } catch (e2:Error) { return; }
			for (var i:int = 0; i < n; i++)
			{
				var c:DisplayObjectContainer = null;
				try { c = d.getChildAt(i) as DisplayObjectContainer; } catch (e3:Error) {}
				if (c) walkStop(c, depth + 1);
			}
		}

		private function resumeTimelines():void
		{
			for each (var mc:MovieClip in stoppedClips)
			{
				try { mc.play(); } catch (e:Error) {}
			}
			stoppedClips = [];
		}

		private function onSeek(e:Event):void
		{
			var mc:MovieClip = contentRoot as MovieClip;
			if (!mc) return;
			try
			{
				var playing:Boolean = true;
				try { playing = mc["isPlaying"]; } catch (e1:Error) {}
				if (playing) mc.gotoAndPlay(menu.seekFrame);
				else mc.gotoAndStop(menu.seekFrame);
			}
			catch (e2:Error)
			{
			}
		}

		// =================================================================== per-frame

		private function onActivity(e:Event):void
		{
			if (e is MouseEvent) checkTouchScale(e as MouseEvent);
			// a finger on the game's input text: the phone's keyboard (see SoftKeys)
			if (ON_PHONE && softKeys && e is MouseEvent && e.type == MouseEvent.MOUSE_DOWN)
				softKeys.tap(e.target as DisplayObject);
			lastActivity = getTimer();
			btnAlpha = 1;
			pauseBtn.alpha = 1;
			pauseBtn.visible = !paused;
		}

		/** lines from the game's helper code (tools/so-shim/bwekh/Protos.as) into the log */
		private var protosTick:int = 0;
		private var protosRead:int = 0;
		private function readProtos():void
		{
			try
			{
				var dom:ApplicationDomain = loader ? loader.contentLoaderInfo.applicationDomain : null;
				if (!dom || !dom.hasDefinition("bwekh.Protos")) return;
				// (untyped: the game's own Array class, "as Array" would give null)
				var m:Object = Object(dom.getDefinition("bwekh.Protos")).messages;
				while (m && protosRead < int(m.length)) Log.write("player: " + m[protosRead++]);
			}
			catch (e:Error) {}
		}

		/** frames per second AIR really gives an AS3 game (logged every 5 s for the first half minute) */
		private var fpsFrames:int = 0;
		private var fpsFrom:int = 0;
		private var fpsLogs:int = 0;
		private var fpsLongest:int = 0;
		private var fpsLast:int = 0;

		private function countFps():void
		{
			var t:int = getTimer();
			if (fpsLast > 0) fpsLongest = Math.max(fpsLongest, t - fpsLast);
			fpsLast = t;
			if (fpsFrom == 0) { fpsFrom = t; fpsFrames = 0; fpsLongest = 0; return; }
			fpsFrames++;
			if (t - fpsFrom >= 5000)
			{
				Log.write("perf: AIR " + (fpsFrames * 1000 / (t - fpsFrom)).toFixed(1) + " fps (stage asks " + stage.frameRate +
					"), longest frame " + fpsLongest + " ms");
				fpsFrom = t;
				fpsFrames = 0;
				fpsLongest = 0;
				fpsLogs++;
			}
		}

		private function onFrame(e:Event):void
		{
			if (closed) return;
			if (airInited && !legacy && !paused && fpsLogs < 6) countFps();
			if (airInited && !legacy && ++protosTick % 30 == 0) readProtos();
			else if (paused) fpsLast = fpsFrom = 0;
			if (stage && (stage.stageWidth != laidW || stage.stageHeight != laidH)) layout();
			if (guarding) checkStage();
			if (renderDue > 0 && getTimer() >= renderDue && stage)
			{
				renderDue = 0;
				setupRenderScale(stage.stageWidth, stage.stageHeight);
			}
			// pause button fades out after 5 seconds without touches
			if (!paused)
			{
				var idle:int = getTimer() - lastActivity;
				if (idle > 5000 && btnAlpha > 0)
				{
					btnAlpha = Math.max(0, btnAlpha - 0.08);
					pauseBtn.alpha = btnAlpha;
				}
				pauseBtn.visible = btnAlpha > 0.01;
			}
			else
			{
				pauseBtn.visible = false;
			}

			// keep the stage in our mode — games love to change it
			if (stage.scaleMode != StageScaleMode.NO_SCALE || stage.align != StageAlign.TOP_LEFT)
			{
				stage.scaleMode = StageScaleMode.NO_SCALE;
				stage.align = StageAlign.TOP_LEFT;
				layout();
			}

			if (wantThumb && !paused) tryThumb();
			if (legacy && !legacy.data && !paused) legacy.hook(contentRoot as MovieClip);

			if (status && status.visible && getTimer() > statusUntil) status.visible = false;

			if (!paused && !preparingLibs)
			{
				var since:int = getTimer() - airStartTime;
				if (stageFix && !airInited && since >= waitLogAt)
				{
					// (the second start of a #1009 game: where AIR is with it)
					waitLogAt = since + 2000;
					var li:LoaderInfo = null;
					try { li = loader ? loader.contentLoaderInfo : null; } catch (le:Error) {}
					var cr:DisplayObject = contentRoot;
					Log.write("player: waiting for AIR " + since + " ms: loaded " + (li ? li.bytesLoaded + "/" + li.bytesTotal : "?") +
						", content " + cr + (cr ? " on stage " + (cr.stage != null) : ""));
					Log.flush();
				}
				if (!airInited && since > 8000) cantPlay("AIR didn't load it in 8 s");
				else if (airInited && !blankChecked && since > 4000)
				{
					blankChecked = true;
					var b:BitmapData = captureAir();
					if (b && isUniform(b))
					{
						Log.write("player: nothing drawn 4 s after start (all 0x" + b.getPixel(0, 0).toString(16) + "): what the game has");
						logTree(contentRoot, 0, { n: 0 });
						Log.flush();
					}
				}
			}
		}

		// =================================================================== thumbnail

		private function tryThumb():void
		{
			if (!contentRoot) return;
			thumbFrames++;
			// first rendered frame, then a few retries if it was blank
			// (games often start with a blank or black loading screen: keep trying for ~30 s)
			if ([2, 20, 60, 120, 240, 480, 900].indexOf(thumbFrames) < 0) return;
			var bmd:BitmapData = captureAir();
			if (bmd && !isUniform(bmd))
			{
				lib.saveThumb(item, bmd);
				wantThumb = false;
				Log.write("player: thumbnail saved at frame " + thumbFrames);
			}
			if (thumbFrames >= 900) wantThumb = false;
		}

		private function thumbSize():Rectangle
		{
			var max:Number = 256;
			var sc:Number = Math.min(1, max / Math.max(cw, ch));
			return new Rectangle(0, 0, Math.max(1, Math.round(cw * sc)), Math.max(1, Math.round(ch * sc)));
		}

		/** the game's display objects, for a game that shows nothing (a few levels, a few dozen lines) */
		private function logTree(d:DisplayObject, depth:int, count:Object):void
		{
			if (!d || depth > 3 || count.n >= 40) return;
			count.n++;
			var line:String = "";
			for (var i:int = 0; i < depth; i++) line += "  ";
			try
			{
				line += flash.utils.getQualifiedClassName(d) + " '" + d.name + "' vis " + d.visible + " a " + d.alpha.toFixed(2) +
					" at " + Math.round(d.x) + "," + Math.round(d.y) + " sc " + d.scaleX.toFixed(2) + "x" + d.scaleY.toFixed(2) +
					" size " + Math.round(d.width) + "x" + Math.round(d.height);
				var mc:MovieClip = d as MovieClip;
				if (mc) line += " frame " + mc.currentFrame + "/" + mc.totalFrames + " loaded " + mc.framesLoaded;
				if (d.mask) line += " masked";
				if (d.transform && d.transform.colorTransform && d.transform.colorTransform.redMultiplier != 1)
					line += " color x" + d.transform.colorTransform.redMultiplier.toFixed(2);
			}
			catch (e:Error) { line += " (" + e.message + ")"; }
			var c:DisplayObjectContainer = d as DisplayObjectContainer;
			if (c) line += " children " + c.numChildren;
			Log.write("player:   " + line);
			if (c)
			{
				for (var k:int = 0; k < c.numChildren && count.n < 40; k++)
				{
					try { logTree(c.getChildAt(k), depth + 1, count); } catch (e2:Error) {}
				}
			}
		}

		private function captureAir():BitmapData
		{
			try
			{
				var r:Rectangle = thumbSize();
				var bmd:BitmapData = new BitmapData(r.width, r.height, false, 0x000000);
				var m:Matrix = new Matrix();
				m.scale(r.width / cw, r.height / ch);
				bmd.draw(holder, m, null, null, null, true);
				return bmd;
			}
			catch (e:Error)
			{
				Log.error("thumbnail", e);
				wantThumb = false; // security sandbox etc. — don't keep trying
			}
			return null;
		}

		private static function isUniform(b:BitmapData):Boolean
		{
			var first:uint = b.getPixel(0, 0);
			for (var i:int = 0; i < 6; i++)
			{
				for (var j:int = 0; j < 6; j++)
				{
					var px:uint = b.getPixel(int((b.width - 1) * (i + 0.5) / 6), int((b.height - 1) * (j + 0.5) / 6));
					if (Math.abs(int(px & 0xFF) - int(first & 0xFF)) > 6 ||
						Math.abs(int((px >> 8) & 0xFF) - int((first >> 8) & 0xFF)) > 6 ||
						Math.abs(int((px >> 16) & 0xFF) - int((first >> 16) & 0xFF)) > 6)
						return false;
				}
			}
			return true;
		}

		// =================================================================== layout

		private function onResize(e:Event):void
		{
			layout();
		}

		private function checkOrientation(e:TimerEvent):void
		{
			if (closed || !stage) return;
			var W:int = stage.stageWidth, H:int = stage.stageHeight;
			var o:String = "";
			try { o = stage.orientation + "/" + stage.deviceOrientation; } catch (err:Error) {}
			if (W >= H)
			{
				Log.write("player: screen " + W + "x" + H + " (" + o + "), laid out " + laidW + "x" + laidH);
				if (W != laidW || H != laidH) layout();
				return;
			}
			// The phone is landscape but AIR's stage still has the portrait size (it happens when a
			// game starts right after the previous one closed: the rotations overlap and AIR misses
			// the last one). Asking for landscape again does nothing — it already is. Make the
			// window change for real so AIR measures it again:
			if (!ON_PHONE) return; // a PC window: portrait is the user's choice
			orientFix++;
			fsGraceUntil = getTimer() + 3000;
			var st:Stage = stage;
			if (orientFix == 1)
			{
				// 1) leave and re-enter full screen: the window resizes, AIR re-reads its size
				Log.write("player: still portrait " + W + "x" + H + " (" + o + "): re-entering full screen");
				try { st.displayState = StageDisplayState.NORMAL; } catch (e1:Error) {}
				later(250, function():void { try { st.displayState = StageDisplayState.FULL_SCREEN_INTERACTIVE; } catch (e2:Error) {} });
			}
			else if (orientFix == 2)
			{
				// 2) rotate to portrait and back
				Log.write("player: still portrait " + W + "x" + H + " (" + o + "): rotating back and forth");
				try { st.setAspectRatio(StageAspectRatio.PORTRAIT); } catch (e3:Error) {}
				later(500, function():void { try { st.setAspectRatio(StageAspectRatio.LANDSCAPE); } catch (e4:Error) {} });
			}
			else Log.write("player: still portrait " + W + "x" + H + " (" + o + ")");
			layout();
		}

		private var orientFix:int = 0;

		private function later(ms:int, fn:Function):void
		{
			var t:Timer = new Timer(ms, 1);
			t.addEventListener(TimerEvent.TIMER, function(e:TimerEvent):void { if (!closed) fn(); });
			t.start();
		}

		public function refreshLayout():void
		{
			layout();
		}

		/** the gamepad offers the keys the game's code reads (A/D instead of arrows, H, ...) */
		private function applyGameKeys(found:Array):void
		{
			var lay:Object = settings.padLayout(found);
			Log.write("pad: keys in the code " + (found ? found.join(",") : "-") + " -> " + lay.dpad.join(",") + " / " + lay.buttons.join(",") + (lay.changed ? " (changed)" : ""));
			gamepad.keyLayout = lay.changed ? lay : null;
			gamepad.rebuild();
			if (lay.changed && padOn)
			{
				var names:Array = [];
				for each (var c:int in found) if (Keys.byCode(c)) names.push(Keys.label(c));
				snack("Gamepad keys from the game: " + names.join(" "));
			}
		}

		public function refreshGamepad():void
		{
			padOn = settings.padFor(item.name, item.info ? item.info.keys : null);
			gamepad.rebuild();
			gamepad.visible = padOn;
			layout();
		}

		/** "Hide / Show gamepad" in the pause menu: remembered for this file. */
		private function onTogglePad(e:Event):void
		{
			settings.padFiles[item.name] = !padOn;
			settings.save();
			Log.write("player: gamepad for " + item.name + " -> " + !padOn);
			refreshGamepad();
			setPaused(false);
		}

		private function layout():void
		{
			if (!stage) return;
			var W:Number = stage.stageWidth;
			var H:Number = stage.stageHeight;
			laidW = W;
			laidH = H;
			bg.graphics.clear();
			bg.graphics.beginFill(0x000000);
			bg.graphics.drawRect(0, 0, W, H);
			bg.graphics.endFill();

			var padL:Number = 0;
			var aw:Number = Math.max(10, W);
			var sc:Number = Math.min(aw / cw, H / ch);
			var w:Number = Math.round(cw * sc);
			var h:Number = Math.round(ch * sc);
			contentRect = new Rectangle(Math.round(padL + (aw - w) / 2), Math.round((H - h) / 2), w, h);

			holder.scaleX = holder.scaleY = sc;
			holder.x = contentRect.x;
			holder.y = contentRect.y;
			holder.scrollRect = new Rectangle(0, 0, cw, ch);

			var ins:Object = insetsFn != null ? insetsFn() : { l: 0, t: 0, r: 0, b: 0 };
			gamepad.layout(W, H, ins);
			pauseBtn.x = W - ins.r - pauseBtn.width - M.px(12);
			pauseBtn.y = ins.t + M.px(12);
			menu.layout(W, H);

			if (renderScale < 1 && (W != scaledW || H != scaledH))
			{
				// the screen size changed after the smaller surface was set up (the game was opened
				// from the list held in landscape: the system bars hide a moment later): redo it
				Log.write("player: screen " + W + "x" + H + " after render scale for " + scaledW + "x" + scaledH + ": again");
				resetRenderScale();
				renderTried = false;
				renderWaits = 0;
			}
			// not right away: when the game is opened with the phone already in landscape, the
			// screen is still settling (full screen, the game's first frames) and a smaller
			// surface set up now shows the wrong part of the stage (white screen)
			if (!renderTried) renderDue = getTimer() + 800;
		}

		// =================================================================== render resolution

		/**
		 * Once, in landscape: make the Android surface smaller so the game area is `renderRes`
		 * pixels high. AIR keeps its stage at the full size and simply draws into the smaller
		 * surface 1:1 (what doesn't fit is cut off), and the display stretches the surface to the
		 * screen. So we draw the whole player scaled down by the same factor into the corner
		 * that fits, and touches (in full-screen coordinates) are scaled down natively to match.
		 */
		private function setupRenderScale(W:Number, H:Number):void
		{
			if (renderTried || W <= H || closed) return;
			// video from NetStream is shown by Android on a surface of its own, placed for the
			// full-size stage: with a smaller AIR surface it lands in the wrong place
			if (GameCoords.usesNetStream && !legacy) return;
			var rh:int = settings.renderRes;
			if (rh <= 0 || rh >= contentRect.height) return;
			var nb:NativeBridge = NativeBridge.instance;
			if (!nb || !nb.available) return;
			renderTried = true;
			fullW = W;
			var s:Number = rh / contentRect.height;
			var report:String = nb.setRenderScale(s, true);
			Log.write("player: render resolution " + rh + "p, scale " + s.toFixed(3) + ": " + report);
			if (report && report.indexOf("wait") >= 0 && report.indexOf("->") < 0 && renderWaits++ < 15)
			{
				// Android's view is still in portrait (a game opened right after another one closed):
				// try again when the screen has turned
				renderTried = false;
				setTimeout(function():void {
					if (!closed && stage) setupRenderScale(stage.stageWidth, stage.stageHeight);
				}, 200);
				return;
			}
			if (!report || report.indexOf("->") < 0) return;
			renderScale = s;
			scaledW = W;
			scaledH = H;
			scaleX = scaleY = s;
			// what shows is the bottom-left part of the stage (AIR draws from the GL origin)
			y = H * (1 - s);
		}

		/** First touch with a smaller surface: check that touches arrive scaled (else go back to full size). */
		private function checkTouchScale(e:MouseEvent):void
		{
			if (touchChecked || renderScale >= 1) return;
			var nb:NativeBridge = NativeBridge.instance;
			if (!nb) return;
			touchChecked = true;
			var t:Array = nb.lastTouch().split(",");
			if (t.length < 3 || int(t[0]) <= 0)
			{
				Log.write("player: render resolution: no touch data from Android");
				return;
			}
			var rx:Number = Number(t[1]);
			var ok:Boolean = Math.abs(e.stageX - rx * renderScale) <= Math.abs(e.stageX - rx);
			Log.write("player: touch check: Android x " + Math.round(rx) + ", stage x " + Math.round(e.stageX) +
				(ok ? " (scaled, ok)" : " (not scaled: back to full size)"));
			if (!ok)
			{
				resetRenderScale();
				layout();
			}
		}

		private function resetRenderScale():void
		{
			if (renderScale < 1 && NativeBridge.instance)
			{
				NativeBridge.instance.setRenderScale(1, false);
				Log.write("player: render resolution back to full size");
			}
			renderScale = 1;
			scaleX = scaleY = 1;
			y = 0;
		}
	}
}
