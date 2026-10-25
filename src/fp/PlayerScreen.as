package fp
{
	import flash.display.Bitmap;
	import flash.display.BitmapData;
	import flash.display.DisplayObject;
	import flash.display.DisplayObjectContainer;
	import flash.display.InteractiveObject;
	import flash.display.Loader;
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
	import flash.system.LoaderContext;
	import flash.utils.ByteArray;
	import flash.utils.getTimer;
	import flash.utils.setTimeout;

	import fp.avm1.Vm;
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
			try
			{
				layout();
			}
			catch (err:Error)
			{
				Log.error("player.layout", err);
				snack("Player layout error " + err.errorID + ": " + err.message);
			}
			try
			{
				startAir();
			}
			catch (err2:Error)
			{
				Log.error("player.start", err2);
				snack("Player start error " + err2.errorID + ": " + err2.message);
			}
		}

		public function close():void
		{
			if (closed) return;
			closed = true;
			Log.write("player: close");
			gamepad.releaseAll();
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
			try { SoundMixer.stopAll(); } catch (se:Error) {}
			unloadAir();
			SoundMixer.soundTransform = new SoundTransform(1);
			// stop everything, then leave the output playing silence for a moment (AudioFlush)
			AudioFlush.run();
			dispatchEvent(new Event(Event.CLOSE));
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

		private function startAir():void
		{
			AudioFlush.cancel();
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
			if (!innerBytes && info.as3 === false)
			{
				// ActionScript 1/2: AIR for Android has no AVM1. Rewrite it as an AS3 movie, and either
				// run its code with our AVM1 engine (also animations: their scripts and buttons work as in Flash).
				var useVm:Boolean = true; // Ruffle (when it can't run here) → AVM1
				try { legacy = SwfConvert.convert(bytes, useVm); } catch (ce:Error) { Log.error("convert", ce); legacy = null; }
				if (!legacy || !legacy.swf)
				{
					cantPlay("couldn't convert this old Flash file");
					return;
				}
				Log.write("player: AS1/AS2 file converted (" + (useVm ? "AVM1 engine" : "simple") + "): " + legacy.totalFrames + " frames, " +
					legacy.droppedScripts + " code blocks" + (useVm ? "" : ", timeline scripts kept on " + countKeys(legacy.scripts) + " frames") +
					(legacy.droppedStreams ? ", " + legacy.droppedStreams + " empty sound streams removed" : "") +
					(legacy.movedSounds ? ", " + legacy.movedSounds + " timeline sounds via mixer" : ""));
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
					var sp:ByteArray = SoPatch.patch(bytes);
					Log.write("player: save games: " + (sp ? "on" : "game doesn't use them") + " (" + (getTimer() - t0) + " ms)");
					if (sp) bytes = sp;
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
			loader.contentLoaderInfo.addEventListener(Event.INIT, onAirInit);
			loader.contentLoaderInfo.addEventListener(IOErrorEvent.IO_ERROR, onAirIOError);
			loader.contentLoaderInfo.addEventListener(SecurityErrorEvent.SECURITY_ERROR, onAirLoadError);
			loader.contentLoaderInfo.addEventListener(ErrorEvent.ERROR, onAirLoadError);
			airInited = false;
			blankChecked = false;
			airStartTime = getTimer();
			showStatus("AIR: loading " + item.name + "…");
			loader.uncaughtErrorEvents.addEventListener(UncaughtErrorEvent.UNCAUGHT_ERROR, onAirError);
			holder.addChild(loader);
			if (!legacy) mapStageCoords(true);
			try
			{
				var ctx:LoaderContext = new LoaderContext(false, new ApplicationDomain());
				ctx.allowCodeImport = true;
				loader.loadBytes(bytes, ctx);
			}
			catch (e2:Error)
			{
				cantPlay("AIR refused to load it (" + e2.message + ")");
				return;
			}
			layout();
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

		private function unloadAir():void
		{
			flushSaves("close");
			mapStageCoords(false);
			stopVm();
			if (!loader) return;
			loader.contentLoaderInfo.removeEventListener(Event.INIT, onAirInit);
			loader.contentLoaderInfo.removeEventListener(IOErrorEvent.IO_ERROR, onAirIOError);
			loader.contentLoaderInfo.removeEventListener(SecurityErrorEvent.SECURITY_ERROR, onAirLoadError);
			loader.contentLoaderInfo.removeEventListener(ErrorEvent.ERROR, onAirLoadError);
			loader.uncaughtErrorEvents.removeEventListener(UncaughtErrorEvent.UNCAUGHT_ERROR, onAirError);
			try { loader.close(); } catch (e:Error) {}
			try { loader.unloadAndStop(true); } catch (e2:Error) {}
			if (loader.parent) loader.parent.removeChild(loader);
			loader = null;
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
			Log.write("player: AIR INIT, content=" + contentRoot + ", stage=" + stage.stageWidth + "x" + stage.stageHeight + ", fps=" + stage.frameRate);
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
				vm.display.start(root);
				Log.write("player: AVM1 self-test: clip methods " + (vm.isFunc(vm.objGet(vm.clipProto, "gotoAndPlay")) ? "ok" : "MISSING"));
				Log.write("player: AVM1 engine started (SWF " + legacy.data.version + ", " +
					countKeys(legacy.data.frameActions) + " timelines with code, " + legacy.data.initActions.length + " #initclip)");
			}
			catch (e:Error)
			{
				Log.error("avm1.start", e);
				snack("The ActionScript 1/2 engine couldn't start: " + e.message);
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
					" ms/s, clips " + vm.display.clipCount + ", " + Math.round(vm.instrCount / secs) + " instructions/s");
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
			var now:int = getTimer();
			if (now - lastErrorTime < 6000) return;
			lastErrorTime = now;
			var msg:String = e.error is Error ? (e.error as Error).message
				: e.error is ErrorEvent ? ErrorEvent(e.error).text : String(e.error);
			if (msg.length > 120) msg = msg.substr(0, 120) + "…";
			snack("Error in the SWF: " + msg);
		}

		private function get contentRoot():DisplayObject
		{
			try { return loader ? loader.content : null; } catch (e:Error) {}
			return null;
		}

		private function drawHolderBg(color:uint):void
		{
			holderBg.graphics.clear();
			holderBg.graphics.beginFill(color);
			holderBg.graphics.drawRect(0, 0, cw, ch);
			holderBg.graphics.endFill();
		}

		private function onContentFocus(e:FocusEvent):void
		{
			var io:InteractiveObject = e.target as InteractiveObject;
			if (io && isInContent(io)) lastFocus = io;
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
			if (!loader) return;
			var type:String = down ? KeyboardEvent.KEY_DOWN : KeyboardEvent.KEY_UP;
			var ev:KeyboardEvent = new KeyboardEvent(type, true, false, k.ch, code, k.loc,
				code == 17, code == 18, code == 16);
			var target:InteractiveObject = null;
			var f:InteractiveObject = stage.focus;
			if (f && isInContent(f)) target = f;
			else if (lastFocus && lastFocus.stage && isInContent(lastFocus)) target = lastFocus;
			else target = contentRoot as InteractiveObject;
			if (target && stage.focus != target)
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
				menu.open(item.name, frame, frames, fps, seekable, item.duration,
					settings.gamepadEnabled ? (padOn ? 1 : 0) : -1);
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
			lastActivity = getTimer();
			btnAlpha = 1;
			pauseBtn.alpha = 1;
			pauseBtn.visible = !paused;
		}

		private function onFrame(e:Event):void
		{
			if (closed) return;
			if (stage && (stage.stageWidth != laidW || stage.stageHeight != laidH)) layout();
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

			if (!paused)
			{
				var since:int = getTimer() - airStartTime;
				if (!airInited && since > 8000) cantPlay("AIR didn't load it in 8 s");
				else if (airInited && !blankChecked && since > 4000)
				{
					blankChecked = true;
					var b:BitmapData = captureAir();
					if (b && isUniform(b)) Log.write("player: nothing drawn 4 s after start");
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
			orientFix++;
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
