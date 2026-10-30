package fp.avm1
{
	import flash.display.DisplayObject;
	import flash.display.Loader;
	import flash.display.BitmapData;
	import flash.display.DisplayObjectContainer;
	import flash.display.FrameLabel;
	import flash.display.GradientType;
	import flash.display.Graphics;
	import flash.display.InteractiveObject;
	import flash.display.MovieClip;
	import flash.display.SimpleButton;
	import flash.display.Sprite;
	import flash.display.Stage;
	import flash.events.Event;
	import flash.events.KeyboardEvent;
	import flash.events.MouseEvent;
	import flash.geom.ColorTransform;
	import flash.geom.Matrix;
	import flash.geom.Point;
	import flash.geom.Rectangle;
	import flash.media.Sound;
	import flash.media.SoundTransform;
	import flash.system.ApplicationDomain;
	import flash.text.Font;
	import flash.text.TextField;
	import flash.text.TextFieldAutoSize;
	import flash.text.TextFieldType;
	import flash.utils.ByteArray;
	import flash.utils.Dictionary;
	import flash.utils.getQualifiedClassName;
	import flash.utils.getTimer;
	import flash.utils.Timer;
	import flash.events.TimerEvent;
	import fp.Log;

	/** Display side of the AVM1 engine: clip wrappers, properties, timeline, events. */
	public class VmDisplay
	{
		private var vm:Vm;
		private var data:Avm1Data;

		public var root:MovieClip;
		public var rootClip:AClip;
		public var stage:Stage;
		public var startTime:int = 0;
		public var tick:int = 0;
		public var paused:Boolean = false;

		private var wrappers:Dictionary = new Dictionary(true);
		private var clips:Array = [];
		private var domain:ApplicationDomain;
		private var pressed:AClip;
		private var hover:AClip;
		private var dragging:AClip;
		private var started:Boolean = false;

		// clip event flags (CLIPEVENTFLAGS)
		public static const EV_LOAD:uint = 1 << 0;
		public static const EV_ENTERFRAME:uint = 1 << 1;
		public static const EV_UNLOAD:uint = 1 << 2;
		public static const EV_MOUSEMOVE:uint = 1 << 3;
		public static const EV_MOUSEDOWN:uint = 1 << 4;
		public static const EV_MOUSEUP:uint = 1 << 5;
		public static const EV_KEYDOWN:uint = 1 << 6;
		public static const EV_KEYUP:uint = 1 << 7;
		public static const EV_DATA:uint = 1 << 8;
		public static const EV_INITIALIZE:uint = 1 << 9;
		public static const EV_PRESS:uint = 1 << 10;
		public static const EV_RELEASE:uint = 1 << 11;
		public static const EV_RELEASEOUTSIDE:uint = 1 << 12;
		public static const EV_ROLLOVER:uint = 1 << 13;
		public static const EV_ROLLOUT:uint = 1 << 14;
		public static const EV_DRAGOVER:uint = 1 << 15;
		public static const EV_DRAGOUT:uint = 1 << 16;
		public static const EV_KEYPRESS:uint = 1 << 17;
		public static const EV_CONSTRUCT:uint = 1 << 18;

		// button condition flags (low byte of BUTTONCONDACTION)
		private static const BC_ROLLOVER:int = 0x01;
		private static const BC_ROLLOUT:int = 0x02;
		private static const BC_PRESS:int = 0x04;
		private static const BC_RELEASE:int = 0x08;
		private static const BC_DRAGOUT:int = 0x10;
		private static const BC_DRAGOVER:int = 0x20;
		private static const BC_RELEASEOUTSIDE:int = 0x40;

		public function VmDisplay(vm:Vm)
		{
			this.vm = vm;
			this.data = vm.data;
		}

		// ================================================================= lifecycle

		public function start(root:MovieClip):void
		{
			this.root = root;
			stage = root.stage;
			startTime = getTimer();
			try { domain = root.loaderInfo.applicationDomain; } catch (e:Error) { domain = ApplicationDomain.currentDomain; }
			registerFonts();
			rootClip = wrap(root);
			rootClip.spriteId = 0;
			started = true;
			// #initclip blocks first (class definitions)
			// nothing of the timeline may run before all of them: a class that makes a clip
			// (mx.transitions' OnEnterFrameBeacon) used to start the walk, and the root's frame 1
			// code then ran before the classes it uses were defined
			initClips = true;
			try { for each (var ia:Object in data.initActions) vm.runOn(rootClip, ia.code); }
			finally { initClips = false; }
			if (rootClip.loaded && rootClip.loadQueued)
			{
				// an #initclip block touched _root (OnEnterFrameBeacon's createEmptyMovieClip): its
				// load got queued, and ran only when the main timeline was on frame 2 already — the
				// frame 1 code (945a's player set-up) never ran. Load it now, on frame 1.
				var rest:Array = [];
				for each (var gq:Object in gotoQueue) if (!(gq.load && gq.c == rootClip)) rest.push(gq);
				gotoQueue = rest;
				loadVia = "start"; loadClip(rootClip);
			}
			else initClip(rootClip);
			walk(root, 0);
			root.addEventListener(Event.REMOVED, onAnyRemoved);
			root.addEventListener(Event.ADDED, onAnyAdded);
			noteTree(root, 0);
			if (vm.debug) vm.log("avm1: start, stage " + stage + ", root parent " + root.parent);
			if (stage) listen();
			else root.addEventListener(Event.ADDED_TO_STAGE, onRootAdded);
		}

		/** fonts of the movie, for text fields created by code (createTextField + embedFonts) */
		private function registerFonts():void
		{
			for each (var id:int in data.fonts)
			{
				try
				{
					var cls:Class = domain.getDefinition(AbcGen.FONT + id) as Class;
					if (cls) Font.registerFont(cls);
				}
				catch (e:Error)
				{
					if (vm.debug) vm.log("avm1: font " + id + " not registered: " + e.message);
				}
			}
		}

		private function onRootAdded(e:Event):void
		{
			root.removeEventListener(Event.ADDED_TO_STAGE, onRootAdded);
			stage = root.stage;
			if (started && stage) listen();
		}

		private function listen():void
		{
			{
				stage.addEventListener(Event.ENTER_FRAME, onEnterFrame);
				stage.addEventListener(Event.FRAME_CONSTRUCTED, onFrameConstructed);
				stage.addEventListener(Event.EXIT_FRAME, onExitFrame);
				stage.addEventListener(MouseEvent.MOUSE_DOWN, onMouseDown, true, 50);
				stage.addEventListener(MouseEvent.MOUSE_UP, onMouseUp, true, 50);
				stage.addEventListener(MouseEvent.MOUSE_MOVE, onMouseMove, true, 50);
				stage.addEventListener(KeyboardEvent.KEY_DOWN, onKeyDown, false, 50);
				stage.addEventListener(KeyboardEvent.KEY_UP, onKeyUp, false, 50);
			}
		}

		public function dispose():void
		{
			vm.dead = true;
			if (root) root.removeEventListener(Event.ADDED_TO_STAGE, onRootAdded);
			if (root) root.removeEventListener(Event.REMOVED, onAnyRemoved);
			if (root) root.removeEventListener(Event.ADDED, onAnyAdded);
			deadAt = getTimer();
			sweep();
			try { stopTree(root); } catch (e:Error) {}
			// and every clip that left the stage (it may still be alive, playing its sound)
			checkOffStage();
			for (var od:* in offStage) try { stopTree(od as DisplayObject); } catch (e1:Error) {}
			for each (var pd:DisplayObject in leaving) try { stopTree(pd); (pd as Sprite).soundTransform = new SoundTransform(0); } catch (e1b:Error) {}
			leaving = [];
			if (stage)
			{
				stage.removeEventListener(Event.ENTER_FRAME, onEnterFrame);
				stage.removeEventListener(Event.FRAME_CONSTRUCTED, onFrameConstructed);
				stage.removeEventListener(Event.EXIT_FRAME, onExitFrame);
				stage.removeEventListener(MouseEvent.MOUSE_DOWN, onMouseDown, true);
				stage.removeEventListener(MouseEvent.MOUSE_UP, onMouseUp, true);
				stage.removeEventListener(MouseEvent.MOUSE_MOVE, onMouseMove, true);
				stage.removeEventListener(KeyboardEvent.KEY_DOWN, onKeyDown);
				stage.removeEventListener(KeyboardEvent.KEY_UP, onKeyUp);
			}
			vm.lib.dispose();
			clips = [];
			started = false;
		}

		/**
		 * Clips that left the stage. In Flash a clip taken off the timeline is gone, sound and all;
		 * in AIR it lives on until it is garbage collected — playing its timeline, and its stream
		 * sound with it: the old scene's music goes on under the new one, and on after the game is
		 * closed. So a clip that stays off the stage is muted (and gets its sound back if it returns).
		 */
		private var leaving:Array = [];
		private var offStage:Dictionary = new Dictionary(true);
		private var offCount:int = 0;
		private var offLogged:int = 0;

		// ---- clips' stream sounds (SwfConvert took them out of the SWF: we play them)
		/** clip -> { id, v: Voice, lastFrame } (null: a clip without a stream) */
		private var streamStates:Dictionary = new Dictionary(true);
		private var streamSounds:Object = {};
		private var streamLogs:int = 0;

		/** each frame: a clip's stream plays while the clip plays through its frames, in step with it */
		private function updateStreams():void
		{
			for (var k:* in streamStates)
			{
				var st:Object = streamStates[k];
				if (!st) continue;
				var mc:MovieClip = k as MovieClip;
				var info:Object = data.streams[st.id];
				var f:int = mc.currentFrame;
				// playing: by AIR, or stepped frame by frame by our engine (a clip it drives: AIR's
				// isPlaying is false then, yet the frames go on)
				var playing:Boolean = st.lastFrame > 0 && f != st.lastFrame;
				if (!playing) try { playing = mc["isPlaying"]; } catch (e:Error) {}
				st.lastFrame = f;
				var active:Boolean = !paused && !vm.dead && mc.stage != null && playing && f >= info.first && f <= info.last;
				if (!active)
				{
					if (st.v) { st.v.stop(); st.v = null; }
					continue;
				}
				var ms:Number = streamSample(info, f) / info.rate * 1000;
				var v:Voice = st.v as Voice;
				if (v && !v.done && Math.abs(v.position - ms) < 400) continue;
				if (v) v.stop();
				var snd:Sound = streamSound(st.id, info);
				st.v = snd ? vm.lib.playStream(snd, ms, "stream" + st.id) : null;
				if (vm.debug && streamLogs++ < 20) vm.log("avm1: clip stream " + st.id + " from " + Math.round(ms) + " ms (frame " + f + ")" + (st.v ? "" : ": couldn't play"));
			}
		}

		/** first sample of frame f of a stream (frames without a block go on at the stream's pace) */
		private function streamSample(info:Object, f:int):Number
		{
			if (!info.arr)
			{
				var arr:Array = [];
				var cur:Number = 0;
				for (var i:int = info.first; i <= info.last; i++)
				{
					if (info.at[i] !== undefined) cur = info.at[i];
					arr[i] = cur;
					cur += info.perFrame;
				}
				info.arr = arr;
			}
			return info.arr[f] || 0;
		}

		private function streamSound(id:int, info:Object):Sound
		{
			var snd:Sound = streamSounds[id] as Sound;
			if (snd) return snd;
			try
			{
				var m:ByteArray = info.mp3;
				snd = new Sound();
				m.position = 0;
				while (m.bytesAvailable > 0) snd.loadCompressedDataFromByteArray(m, Math.min(32768, m.bytesAvailable));
				streamSounds[id] = snd;
			}
			catch (e:Error) { vm.warnOnce("stream sound " + id + ": " + e.message); snd = null; }
			return snd;
		}

		// ---- clips of closed games
		/** every movie clip a game had (weak): owner VmDisplay */
		private static var everyClip:Dictionary = new Dictionary(true);
		private static var sweeper:Timer;
		private static var sweptMute:Dictionary = new Dictionary(true);
		private static var sweepLogs:int = 0;
		/** when the game was closed (0: running) */
		private var deadAt:int = 0;

		private function onAnyAdded(e:Event):void
		{
			// (a clip comes with its children already in it: their own ADDED never reached the root)
			noteTree(e.target as DisplayObject, 0);
		}

		private function noteTree(d:DisplayObject, depth:int):void
		{
			if (!d || depth > 30) return;
			if (d is MovieClip) note(d);
			var c:DisplayObjectContainer = d as DisplayObjectContainer;
			if (!c) return;
			for (var i:int = 0; i < c.numChildren; i++)
			{
				var ch:DisplayObjectContainer = null;
				try { ch = c.getChildAt(i) as DisplayObjectContainer; } catch (e:Error) {}
				if (ch) noteTree(ch, depth + 1);
			}
		}

		private function note(d:DisplayObject):void
		{
			everyClip[d] = this;
			if (streamStates[d] === undefined)
			{
				var cn:String = getQualifiedClassName(d);
				if (cn.indexOf(AbcGen.SPRITE) == 0)
				{
					var sid:int = int(cn.substr(AbcGen.SPRITE.length));
					streamStates[d] = data.streams[sid] ? { id: sid, v: null, lastFrame: -1 } : null;
					if (data.streams[sid] && vm.debug && streamLogs++ < 40)
						vm.log("avm1: clip with a stream sound: " + d.name + " #" + sid + ", stream on frames " + data.streams[sid].first + "-" + data.streams[sid].last);
				}
			}
			if (!sweeper)
			{
				sweeper = new Timer(500);
				sweeper.addEventListener(TimerEvent.TIMER, function(te:TimerEvent):void { sweep(); });
				sweeper.start();
			}
		}

		/**
		 * A clip of a closed game that plays (again): its stream sound is heard in the next game.
		 * Stop and mute it, whoever restarted it.
		 */
		public static function sweep():void
		{
			var playing:int = 0, alive:int = 0, onStage:int = 0;
			var names:Array = [];
			for (var k:* in everyClip)
			{
				var owner:VmDisplay = everyClip[k] as VmDisplay;
				if (!owner || !owner.vm.dead) continue;
				alive++;
				var mc:MovieClip = k as MovieClip;
				if (!mc) continue;
				if (mc.stage) onStage++;
				var p:Boolean = false;
				try { p = mc["isPlaying"]; } catch (e:Error) { p = mc.totalFrames > 1; }
				if (p)
				{
					playing++;
					if (names.length < 6) names.push(mc.name + "(" + getQualifiedClassName(mc) + " " + mc.currentFrame + "/" + mc.totalFrames + ")");
					try { mc.stop(); } catch (e1:Error) {}
				}
				if (!sweptMute[mc]) { sweptMute[mc] = true; try { mc.soundTransform = new SoundTransform(0); } catch (e2:Error) {} }
			}
			if ((playing || onStage) && sweepLogs++ < 20)
				Log.write("avm1: clips of a closed game: " + alive + " alive, " + onStage + " on the stage, " + playing +
					" were playing (stopped and muted)" + (names.length ? ": " + names.join(", ") : ""));
		}

		private function onAnyRemoved(e:Event):void
		{
			if (e.target is Sprite && leaving.length < 2000) leaving.push(e.target);
		}

		private function checkOffStage():void
		{
			var d:DisplayObject;
			if (leaving.length)
			{
				var list:Array = leaving;
				leaving = [];
				for each (d in list)
				{
					if (d.stage || offStage[d] !== undefined) continue;
					var sp:Sprite = d as Sprite;
					try
					{
						offStage[d] = sp.soundTransform;
						sp.soundTransform = new SoundTransform(0);
						offCount++;
						if (vm.debug && offLogged++ < 5) vm.log("avm1: clip off the stage muted: " + d.name + " (" + getQualifiedClassName(d) + ")");
					}
					catch (e:Error) {}
				}
			}
			if (!offCount) return;
			var back:Array = [];
			for (var k:* in offStage) if ((k as DisplayObject).stage) back.push(k);
			for each (d in back)
			{
				try { (d as Sprite).soundTransform = offStage[d] || new SoundTransform(); } catch (e2:Error) {}
				delete offStage[d];
				offCount--;
			}
		}

		/** stop every timeline of the movie (so nothing restarts its sounds after closing) */
		private function stopTree(d:DisplayObject):void
		{
			var mc:MovieClip = d as MovieClip;
			if (mc) mc.stop();
			var cont:DisplayObjectContainer = d as DisplayObjectContainer;
			if (!cont) return;
			for (var i:int = 0; i < cont.numChildren; i++)
			{
				try { stopTree(cont.getChildAt(i)); } catch (e:Error) {}
			}
		}

		public function get clipCount():int { return clips.length; }

		// ================================================================= wrappers

		public function wrap(d:DisplayObject):AClip
		{
			if (!d) return null;
			var c:AClip = wrappers[d];
			if (c) return c;
			var proto:AObject = vm.clipProto;
			if (d is SimpleButton) proto = vm.buttonProto;
			else if (d is TextField) proto = vm.textProto;
			c = new AClip(proto, d);
			if (d is SimpleButton) { c.isButton = true; c.kind = "object"; }
			if (d is TextField) { c.isText = true; c.kind = "object"; }
			var cn:String = getQualifiedClassName(d);
			if (cn.indexOf(AbcGen.SPRITE) == 0 || cn.indexOf(AbcGen.BUTTON) == 0) c.spriteId = int(cn.substr(5));
			if (d == root) c.spriteId = 0;
			wrappers[d] = c;
			if (d is MovieClip) note(d);
			return c;
		}

		/** wrapper that is also initialized (frame scripts, events) */
		public function clipOf(d:DisplayObject):AClip
		{
			var c:AClip = wrap(d);
			if (c && started && !c.loaded) initClip(c);
			return c;
		}

		private function walk(cont:DisplayObjectContainer, depth:int, inBtn:Boolean = false):void
		{
			if (depth > 30) return;
			var n:int = 0;
			try { n = cont.numChildren; } catch (e:Error) { return; }
			for (var i:int = 0; i < n; i++)
			{
				var d:DisplayObject = null;
				try { d = cont.getChildAt(i); } catch (e2:Error) {}
				if (!d) continue;
				visit(d, depth, inBtn);
			}
		}

		private function visit(d:DisplayObject, depth:int, inBtn:Boolean):void
		{
			if (d is MovieClip || d is SimpleButton || d is TextField)
			{
				var c:AClip = wrappers[d];
				if (!c || !c.loaded)
				{
					c = wrap(d);
					if (inBtn) c.inButton = true;
					placingTimeline = true;
					try { initClip(c); } finally { placingTimeline = false; }
				}
			}
			if (d is DisplayObjectContainer) walk(d as DisplayObjectContainer, depth + 1, inBtn);
			else if (d is SimpleButton)
			{
				// clips inside the button's look (an animated enemy, with its own sounds) live
				// in its states, which aren't children
				var sb:SimpleButton = d as SimpleButton;
				var seen:Array = [];
				for each (var st:DisplayObject in [sb.upState, sb.overState, sb.downState])
				{
					if (!st || seen.indexOf(st) >= 0) continue;
					seen.push(st);
					visit(st, depth + 1, true);
				}
				watchButtonStates(sb);
			}
		}

		// ----------------------------------------------------------------- button looks

		/** SimpleButton -> look shown now */
		private var btnShown:Dictionary = new Dictionary(true);

		/**
		 * AIR builds all looks of a button at once and their clips keep playing while hidden. In
		 * Flash a look only exists while it is shown: a clip in the "over" look with a sound
		 * (Masyanya talking when the mouse is on her) played forever here. Hidden looks are
		 * stopped now, and a look starts from its first frame when it's shown, as in Flash.
		 */
		private function watchButtonStates(sb:SimpleButton):void
		{
			if (btnShown[sb] !== undefined) return;
			if (data.rootStream)
			{
				sb.addEventListener(MouseEvent.MOUSE_UP, kickRootStream);
				sb.addEventListener(MouseEvent.ROLL_OUT, kickRootStream);
			}
			// the same records in "over" and "down": one look in Flash, which keeps playing when
			// the button is pressed (AIR made two copies: pressing restarted it)
			if (sb.overState && sb.downState && sb.overState != sb.downState && sameLook(sb.overState, sb.downState, 0))
			{
				try { sb.downState = sb.overState; } catch (e:Error) {}
			}
			var animated:Boolean = false;
			for each (var l:DisplayObject in [sb.upState, sb.overState, sb.downState])
				if (l && hasClips(l, 0)) animated = true;
			btnShown[sb] = null;
			if (!animated) return;
			showLook(sb, "up", true);
			sb.addEventListener(MouseEvent.ROLL_OVER, function(e:MouseEvent):void { showLook(sb, e.buttonDown ? "down" : "over", false); });
			sb.addEventListener(MouseEvent.ROLL_OUT, function(e:MouseEvent):void { showLook(sb, "up", false); });
			sb.addEventListener(MouseEvent.MOUSE_DOWN, function(e:MouseEvent):void { showLook(sb, "down", false); });
			sb.addEventListener(MouseEvent.MOUSE_UP, function(e:MouseEvent):void { showLook(sb, "over", false); });
		}

		/**
		 * On Android, pressing a button silenced the main timeline's stream sound (a cartoon's
		 * voices) until the timeline was stopped and started again (what pause / continue did).
		 * So after a button is used: stop the main timeline for one frame and play it on.
		 */
		private var kickFrame:int = -1;

		private function kickRootStream(e:MouseEvent):void
		{
			if (vm.dead || !root || kickFrame >= 0) return;
			var playing:Boolean = false;
			try { playing = root["isPlaying"] === true; } catch (err:Error) {}
			if (!playing) return;
			kickFrame = root.currentFrame;
			root.stop();
			root.addEventListener(Event.ENTER_FRAME, kickPlay);
		}

		private function kickPlay(e:Event):void
		{
			root.removeEventListener(Event.ENTER_FRAME, kickPlay);
			var f:int = kickFrame;
			kickFrame = -1;
			if (vm.dead) return;
			var playing:Boolean = false;
			try { playing = root["isPlaying"] === true; } catch (err:Error) {}
			// the game's own code moved or started it meanwhile: leave it
			if (playing || root.currentFrame != f) return;
			if (vm.debug) vm.log("avm1: main timeline restarted after a button (stream sound)");
			root.play();
		}

		/** two looks built from the same records (same kinds of objects at the same places) */
		private static function sameLook(a:DisplayObject, b:DisplayObject, level:int):Boolean
		{
			if (!a || !b) return a == b;
			if (getQualifiedClassName(a) != getQualifiedClassName(b)) return false;
			var ma:Matrix = a.transform.matrix, mb:Matrix = b.transform.matrix;
			if (Math.abs(ma.a - mb.a) > 0.001 || Math.abs(ma.b - mb.b) > 0.001 || Math.abs(ma.c - mb.c) > 0.001 ||
				Math.abs(ma.d - mb.d) > 0.001 || Math.abs(ma.tx - mb.tx) > 0.05 || Math.abs(ma.ty - mb.ty) > 0.05) return false;
			var ca:DisplayObjectContainer = a as DisplayObjectContainer, cb:DisplayObjectContainer = b as DisplayObjectContainer;
			if (!ca || !cb || level > 0) return true;
			if (ca.numChildren != cb.numChildren) return false;
			for (var i:int = 0; i < ca.numChildren; i++)
				if (!sameLook(ca.getChildAt(i), cb.getChildAt(i), level + 1)) return false;
			return true;
		}

		private static function hasClips(d:DisplayObject, level:int):Boolean
		{
			if (d is MovieClip && MovieClip(d).totalFrames > 1) return true;
			var c:DisplayObjectContainer = d as DisplayObjectContainer;
			if (!c || level > 4) return false;
			for (var i:int = 0; i < c.numChildren; i++) if (hasClips(c.getChildAt(i), level + 1)) return true;
			return false;
		}

		private function showLook(sb:SimpleButton, state:String, first:Boolean):void
		{
			var shown:DisplayObject = state == "down" ? sb.downState : state == "over" ? sb.overState : sb.upState;
			if (!first && btnShown[sb] == shown) return;   // the same look stays: keeps playing
			btnShown[sb] = shown;
			var done:Array = [];
			for each (var l:DisplayObject in [sb.upState, sb.overState, sb.downState])
			{
				if (!l || l == shown || done.indexOf(l) >= 0) continue;
				done.push(l);
				runLook(l, false, false, 0);
			}
			// at the start the up look just keeps playing (only its sound is started)
			if (shown) runLook(shown, true, !first, 0);
		}

		/** start (from frame 1 when restart) or stop every clip of a button look, with its sound */
		private function runLook(d:DisplayObject, play:Boolean, restart:Boolean, level:int):void
		{
			var mc:MovieClip = d as MovieClip;
			try
			{
				if (mc && mc.totalFrames > 1)
				{
					if (!play) mc.gotoAndStop(1);
					else if (restart) mc.gotoAndPlay(1);
				}
			}
			catch (e:Error) {}
			var c:AClip = wrappers[d];
			var rec:Object = c && c.spriteId >= 0 ? data.lookSounds[c.spriteId] : null;
			if (rec)
			{
				try
				{
					if (play) { vm.lib.stopTimelineSound(rec.id); vm.lib.timelineSound(rec); }
					else vm.lib.stopTimelineSound(rec.id);
				}
				catch (e2:Error) {}
			}
			var dc:DisplayObjectContainer = d as DisplayObjectContainer;
			if (!dc || level > 4) return;
			for (var i:int = 0; i < dc.numChildren; i++) runLook(dc.getChildAt(i), play, restart, level + 1);
		}


		private function initClip(c:AClip):void
		{
			if (c.loaded) return;
			c.loaded = true;
			c.placedByTimeline = placingTimeline;
			clips.push(c);
			var d:DisplayObject = c.d;
			var parent:AClip = parentOf(c);
			var key:String = (parent ? parent.spriteId : -1) + "/" + (d.name || "");
			if (!c.events && data.clipActions[key]) c.events = data.clipActions[key];
			if (data.placedTextVars[key]) c.textVar = data.placedTextVars[key];
			d.addEventListener(Event.REMOVED_FROM_STAGE, onRemoved);
			if (d is TextField)
			{
				var tf:TextField = d as TextField;
				if (tf.type == TextFieldType.INPUT) tf.addEventListener(Event.CHANGE, onTextInput);
				else tf.mouseEnabled = false;
				syncText(c);
				return;
			}
			var mc:MovieClip = d as MovieClip;
			// in Flash 5-8 only clips with mouse handlers catch the mouse; in AS3 every clip would
			// (a dragged cursor clip would block every button under it)
			// (the main timeline too: text or a picture on it over a button must not take the click)
			if (mc) mc.mouseEnabled = isMouseTarget(c);
			if (mc && c.spriteId >= 0)
			{
				var frames:Object = {};
				var fk:String;
				for (fk in data.frameActions[c.spriteId]) frames[fk] = true;
				for (fk in data.frameSounds[c.spriteId]) frames[fk] = true;
				{
					for (var k:String in frames)
					{
						var f:int = int(k);
						if (f >= 1 && f <= mc.totalFrames)
						{
							try { mc.addFrameScript(f - 1, frameRunner(c, f)); } catch (e:Error) {}
						}
					}
				}
			}
			// AS2 class registered for this symbol (Object.registerClass / linkage class)
			var ctor:* = registeredFor(c.spriteId);
			if (ctor is AObject)
			{
				var p:* = vm.getMember(ctor, "prototype");
				if (p is AObject) c.proto = p;
			}
			fireClip(c, EV_INITIALIZE);
			if (ctor is AObject) vm.callHandler(ctor, c, []);
			// the class (its prototype) may give the clip onPress / onRelease...
			if (ctor is AObject && mc) mc.mouseEnabled = isMouseTarget(c);
			if (vm.debug && ctor is AObject) vm.log("avm1: class for #" + c.spriteId + " mouse " + (mc ? mc.mouseEnabled : "-") + " onPress " + vm.getMember(c, "onPress") + " enabled " + vm.getMember(c, "enabled"));
			fireClip(c, EV_CONSTRUCT);
			// placed by its parent's timeline on a frame whose code comes first in the file: Flash
			// runs that code before this clip's onClipEvent(load) and first frame code (it often
			// sets up what they use)
			var par:AClip = placingTimeline ? parent : null;
			if (par && par.loaded && parentScriptPending(par))
			{
				if (!par.deferredKids) { par.deferredKids = []; kidOwners.push(par); }
				par.deferredKids.push(c);
				c.deferredBy = par;
				return;
			}
			if (vm.running)
			{
				// made while code runs (a goto, attachMovie): Flash runs onClipEvent(load) and the
				// clip's first frame code after that code
				c.loadQueued = true;
				gotoQueue.push({ c: c, load: true });
				return;
			}
			loadVia = "init"; loadClip(c);
		}

		private var loadVia:String = "";

		/** onClipEvent(load) / onLoad, then the code of the frame the clip is on */
		private function loadClip(c:AClip):void
		{
			c.loadQueued = false;
			c.loadTick = tick;
			if (vm.watch && vm.watch["@load"] && c.spriteId == int(vm.watch["@load"])) { var st:* = null; try { st = (new Error("x") as Object).getStackTrace(); } catch (e0:Error) {} vm.log("avm1: loadClip " + targetPath(c, true) + " running=" + vm.running + " via " + loadVia); }
			fireClip(c, EV_LOAD);
			var onLoad:* = vm.getMember(c, "onLoad");
			if (vm.isFunc(onLoad)) vm.callHandler(onLoad, c, []);
			var mc:MovieClip = c.d as MovieClip;
			if (mc && c.spriteId >= 0)
			{
				rfVia = "loadClip"; runFrame(c, mc.currentFrame);
				c.initFrame = mc.currentFrame;
				c.initTick = tick;
			}
		}

		private var rfVia:String = "";

		/** clips being set up because the timeline placed them (not attachMovie & co.) */
		private var placingTimeline:Boolean = false;
		private var kidOwners:Array = [];

		/** the parent is on a frame with code that hasn't run yet */
		private function parentScriptPending(p:AClip):Boolean
		{
			var m:MovieClip = p.d as MovieClip;
			if (!m || p.spriteId < 0) return false;
			var f:int = m.currentFrame;
			var acts:Object = data.frameActions[p.spriteId];
			if (!acts || !acts[f]) return false;
			var first:Object = data.actionsFirst[p.spriteId];
			if (!first || !first[f]) return false;
			return !(p.lastRunFrame == f && p.lastRunTick == tick);
		}

		/** run the first frame scripts of the children that waited for p */
		private function flushKids(p:AClip):void
		{
			var kids:Array = p.deferredKids;
			if (!kids) return;
			p.deferredKids = null;
			for each (var k:AClip in kids)
			{
				k.deferredBy = null;
				if (!k.loaded) continue;
				loadVia = "flushKids of " + targetPath(p, true); loadClip(k);
			}
		}

		private function flushAllKids():void
		{
			for (var guard:int = 0; guard < 8 && kidOwners.length; guard++)
			{
				var owners:Array = kidOwners;
				kidOwners = [];
				for each (var p:AClip in owners) flushKids(p);
			}
		}

		private function registeredFor(spriteId:int):*
		{
			if (spriteId <= 0) return null;
			var name:String = data.exportName(spriteId);
			if (!name) return null;
			return vm.registered[name.toLowerCase()];
		}

		private function frameRunner(c:AClip, f:int):Function
		{
			return function():void {
				if (c.deferredBy) return; // runs after its parent's frame script (flushKids)
				if (vm.running)
				{
					// a goto to the frame the clip is already on: Flash doesn't run its code again
					if (c.lastRunFrame == f) return;
					// AIR runs a frame's code right inside a goto; Flash runs it after the code that
					// made the goto: queue it
					for each (var q:Object in gotoQueue) if (q.c == c && q.f == f && !q.load) return;
					gotoQueue.push({ c: c, f: f });
					return;
				}
				// AIR calls a frame's script late (after a goto made inside code, at the end of the
				// frame), when our queue has run it already and its code has moved the clip on: the
				// clip isn't on that frame any more, Flash wouldn't run it (candygirl's game over
				// ran frame 6 again from frame 7 and ended on the empty frame 8)
				var fm:MovieClip = c.d as MovieClip;
				if (fm && fm.currentFrame != f)
				{
					if (vm.watch && vm.watch["@goto"]) vm.log("avm1: @air #" + c.spriteId + " f " + f + " skipped, now on " + fm.currentFrame);
					return;
				}
				// the frame script AIR runs for the frame initClip has run already: not twice
				// (a 35 KB start-up script run again resets the whole game)
				if (c.initFrame == f)
				{
					c.initFrame = -1;
					// (also when the clip has moved on already: that script went there with a
					// nextFrame() of its own — candygirl's game over ran its frame twice and skipped
					// the results screen)
					if (tick - c.initTick <= 1) return;
				}
				c.initFrame = -1;
				if (vm.watch && vm.watch["@goto"]) vm.log("avm1: @air #" + c.spriteId + " f " + f + " tick " + tick);
				rfVia = "AIR";
				var outer:AClip = airScriptClip;
				airScriptClip = c;
				try { runFrame(c, f); } finally { airScriptClip = outer; }
			};
		}

		public function runFrame(c:AClip, f:int):void
		{
			if (vm.dead || c.unloaded) return;
			if (c.inButton && c.d && !c.d.stage) return; // a button look that isn't shown now
			if (c != rootClip && c.d && !c.d.stage && root && root.stage && c.loadTick != tick)
			{
				// off the display list (removed by the timeline): Flash wouldn't run it. (Not one
				// made this frame: AIR is still putting its parent together — candygirl's START
				// countdown was stopped on its first frame that way, and the game never began.)
				var om:MovieClip = c.d as MovieClip;
				if (om) om.stop();
				return;
			}
			if (c.lastRunFrame == f && c.lastRunTick == tick) return;
			c.lastRunFrame = f;
			c.lastRunTick = tick;
			var snds:Object = data.frameSounds[c.spriteId];
			// (the first frame can run twice at start-up: don't double its sounds)
			if (snds && snds[f] && !(c.lastSoundFrame == f && tick - c.lastSoundTick <= 1))
			{
				c.lastSoundFrame = f;
				c.lastSoundTick = tick;
				for each (var rec:Object in snds[f]) vm.lib.timelineSound(rec);
			}
			var frames:Object = data.frameActions[c.spriteId];
			if (frames && frames[f])
			{
				if (!c.ranFrames) c.ranFrames = {};
				c.ranFrames[f] = tick;
				for each (var code:ByteArray in frames[f]) vm.runOn(c, code);
				if (c.stopFrame == f && tick - c.stopTick <= 1)
				{
					c.stopFrame = -1;
					var sm:MovieClip = c.d as MovieClip;
					if (sm) { try { sm.stop(); } catch (se:Error) {} }
				}
			}
			if (c.deferredKids) { if (vm.watch && vm.watch["@load"]) vm.log("avm1: flushKids from runFrame " + targetPath(c, true) + " f=" + f + " running=" + vm.running + " via " + rfVia + " kids " + c.deferredKids.length); flushKids(c); }
		}

		private function onRemoved(e:Event):void
		{
			// one failing clip must not stop the rest of the frame (or the whole player)
			try { onRemovedBody(e); } catch (err:Error) { vm.handlerError("onRemoved", err); }
		}

		/** swapDepths is moving a clip (out and back in): not a removal */
		private var moving:Boolean = false;

		private function onRemovedBody(e:Event):void
		{
			if (moving) return;
			if (e.target != e.currentTarget) return;
			var c:AClip = wrappers[e.currentTarget];
			if (!c || !c.alive) return;
			// a button swapping its up/over/down look: the clip comes back, it isn't gone
			if (c.inButton) return;
			c.alive = false;
			// in Flash a clip that leaves the timeline is gone; in AS3 it would keep playing
			// (and running its frame scripts, e.g. a music loop) off screen — stop it
			try { stopTree(c.d); } catch (e2:Error) {}
			// (and the sounds started on it)
			try { vm.lib.clipRemoved(c); } catch (e3:Error) {}
			fireClip(c, EV_UNLOAD);
			var onUnload:* = vm.getMember(c, "onUnload");
			if (vm.isFunc(onUnload)) vm.callHandler(onUnload, c, []);
			// a timeline clip can come back later (gotoAndPlay back): start over then
			c.loaded = false;
			c.alive = true;
			var i:int = clips.indexOf(c);
			if (i >= 0) clips.splice(i, 1);
			if (pressed == c) pressed = null;
			if (hover == c) hover = null;
		}

		// ================================================================= frame events

		/** test builds: ms spent in the frame events (null = off) */
		public var timing:Object;

		private function onEnterFrame(e:Event):void
		{
			// one failing clip must not stop the rest of the frame (or the whole player)
			try { onEnterFrameBody(e); } catch (err:Error) { vm.handlerError("onEnterFrame", err); }
		}

		/**
		 * AS3's ENTER_FRAME comes before the frame's new objects exist; AS2 onEnterFrame code expects
		 * them (gotoAndStop("game") then onEnterFrame = init, which uses the game's clips). So the
		 * clips' enterFrame code runs at FRAME_CONSTRUCTED, after the display list is built.
		 */
		private var frameStarted:Boolean = false;

		private function onEnterFrameBody(e:Event):void
		{
			if (leaving.length || offCount) checkOffStage();
			try { updateStreams(); } catch (se:Error) {}
			if (paused) return;
			tick++;
			frameStarted = true;
		}

		private function runEnterFrames():void
		{
			frameStarted = false;
			var t0:int = timing ? getTimer() : 0;
			try { runEnterFramesBody(); } catch (err:Error) { vm.handlerError("onEnterFrame", err); }
			if (timing) timing.enter += getTimer() - t0;
		}

		private function runEnterFramesBody():void
		{
			var list:Array = clips.concat();
			for each (var c:AClip in list)
			{
				if (!c.loaded || c.loadTick == tick) continue; // (made this frame: from the next one on)
				// not set up yet (its onClipEvent(load) waits for its parent's frame code or for the
				// code that made it): no enterFrame before load. (A preloader bar placed on the frame
				// whose code says stop() jumped to 100% and started its parent before that stop().)
				if (c.deferredBy || c.loadQueued) continue;
				fireClip(c, EV_ENTERFRAME);
				var oef:* = vm.objGet(c, "onEnterFrame"); // (no child or built-in has that name)
				if (vm.isFunc(oef)) vm.callHandler(oef, c, []);
			}
			for each (c in list)
			{
				if (c.textVar) syncText(c);
			}
		}

		private function onFrameConstructed(e:Event):void
		{
			// one failing clip must not stop the rest of the frame (or the whole player)
			try { onFrameConstructedBody(e); } catch (err:Error) { vm.handlerError("onFrameConstructed", err); }
		}

		/** a goto made by the game's code makes AIR send the frame events right inside that code */
		private var walkPending:Boolean = false;

		/** the #initclip blocks are running (start) */
		private var initClips:Boolean = false;

		/** called when the game's code has ended (Vm): what the frame events skipped meanwhile */
		public function afterCode():void
		{
			if (initClips) return;
			if (walkPending && root)
			{
				walkPending = false;
				walk(root, 0);
			}
			drainGotos(false);
			if (driveRuns.length) runDriveScripts();
		}

		private function onFrameConstructedBody(e:Event):void
		{
			if (!root) return;
			if (vm.running) { walkPending = true; return; }

			var t0:int = timing ? getTimer() : 0;
			walk(root, 0);
			fixDynOrder();
			if (timing) { timing.walk += getTimer() - t0; timing.frames++; }
			if (frameStarted) runEnterFrames();
			if (drives.length) stepDrives();
		}

		public function fireClip(c:AClip, flag:uint, keyCode:int = -1):void
		{
			if (!c.events) return;
			for each (var ev:Object in c.events)
			{
				if (!(ev.flags & flag)) continue;
				if (flag == EV_KEYPRESS && ev.key != keyCode) continue;
				vm.runOn(c, ev.code);
			}
		}

		private function fireAll(flag:uint, keyCode:int = -1):void
		{
			for each (var c:AClip in clips.concat())
			{
				if (c.loaded && c.events) fireClip(c, flag, keyCode);
			}
		}

		/** clips with an onXxx method (onMouseDown...) get it called */
		private function callAll(name:String, args:Array = null):void
		{
			for each (var c:AClip in clips.concat())
			{
				if (!c.loaded || c.isText) continue;
				var f:* = vm.getMember(c, name);
				if (vm.isFunc(f)) vm.callHandler(f, c, args || []);
			}
		}

		// ================================================================= mouse

		/** touches on the player's own controls (gamepad, pause button) aren't the movie's */
		private function inMovie(e:MouseEvent):Boolean
		{
			var t:DisplayObject = e.target as DisplayObject;
			if (!t) return false;
			if (t == root || root.contains(t)) return true;
			// a touch that fell through the movie to its containers (Loader, holder, stage):
			// it's the movie's if it's inside the movie's area. Anything else (gamepad) isn't.
			var a:DisplayObject = root.parent;
			var isAncestor:Boolean = false;
			var guard:int = 0;
			while (a && guard++ < 30)
			{
				if (a == t) { isAncestor = true; break; }
				a = a.parent;
			}
			if (!isAncestor) return false;
			var p:Point = root.globalToLocal(new Point(e.stageX, e.stageY));
			return p.x >= 0 && p.y >= 0 && p.x <= root.loaderInfo.width && p.y <= root.loaderInfo.height;
		}

		/** first clip from the touched object up that reacts to the mouse (button events / onPress...) */
		private function handlerClip(t:DisplayObject):AClip
		{
			var d:DisplayObject = t;
			var guard:int = 0;
			while (d && d != root.parent && guard++ < 60)
			{
				var c:AClip = wrappers[d];
				if (c && c.loaded && isMouseTarget(c)) return c;
				d = d.parent;
			}
			return null;
		}

		/** why a click found no handler: the clips from the target up (test builds) */
		private var chainLogs:int = 0;
		private function logMouseChain(t:DisplayObject):void
		{
			if (chainLogs++ > 20) return;
			var d:DisplayObject = t;
			var s:String = "";
			for (var guard:int = 0; d && d != root.parent && guard < 12; guard++, d = d.parent)
			{
				var c:AClip = wrappers[d];
				s += " | " + d.name + (c ? " #" + c.spriteId + (c.loaded ? "" : " not-loaded") + (c.alive ? "" : " dead") +
					(vm.getMember(c, "eo") !== undefined ? " eo" : "") + (vm.isFunc(vm.getMember(c, "onPress")) ? " onPress" : "") +
					(vm.isFunc(vm.getMember(c, "onRelease")) ? " onRelease" : "") + (vm.getMember(c, "enabled") === false ? " disabled" : "") : " (no wrapper)");
			}
			vm.log("avm1:   chain" + s);
		}

		private function isMouseTarget(c:AClip):Boolean
		{
			if (c.isText) return false;
			if (vm.getMember(c, "enabled") === false) return false;
			if (c.isButton && data.buttonConds[c.spriteId]) return true;
			if (c.events)
			{
				for each (var ev:Object in c.events)
				{
					if (ev.flags & (EV_PRESS | EV_RELEASE | EV_RELEASEOUTSIDE | EV_ROLLOVER | EV_ROLLOUT)) return true;
				}
			}
			for each (var n:String in ["onPress", "onRelease", "onReleaseOutside", "onRollOver", "onRollOut"])
			{
				if (vm.isFunc(vm.getMember(c, n))) return true;
			}
			return false;
		}

		/** press / release / rollOver ... on a clip or button */
		private function mouseAction(c:AClip, clipFlag:uint, buttonFlag:int, method:String):void
		{
			if (!c) return;
			if (c.isButton)
			{
				var conds:Array = data.buttonConds[c.spriteId];
				if (conds)
				{
					var owner:AClip = parentOf(c) || rootClip;
					for each (var bc:Object in conds)
					{
						if (bc.flags & buttonFlag) vm.runOn(owner, bc.code, owner);
					}
				}
			}
			fireClip(c, clipFlag);
			var f:* = vm.getMember(c, method);
			if (vm.isFunc(f)) vm.callHandler(f, c, []);
		}

		/** touches on this object are the player's own (it passes copies on to the movie) */
		public var foreignTarget:DisplayObject;

		private function onMouseDown(e:MouseEvent):void
		{
			// one failing clip must not stop the rest of the frame (or the whole player)
			inInput = true;
			try { onMouseDownBody(e); } catch (err:Error) { vm.handlerError("onMouseDown", err); }
			inInput = false;
		}

		private function onMouseDownBody(e:MouseEvent):void
		{
			if (foreignTarget && e.target == foreignTarget) return;
			if (vm.debug) vm.log("avm1: stage mouse down " + e.stageX + "," + e.stageY + " target " + e.target);
			if (paused || !root || !inMovie(e)) return;
			fireAll(EV_MOUSEDOWN);
			vm.lib.mouseEvent("onMouseDown");
			callAll("onMouseDown");
			var c:AClip = handlerClip(e.target as DisplayObject);
			if (vm.debug) vm.log("avm1: mouse down on " + e.target + " (" + (e.target as DisplayObject).name + ") -> " + (c ? c.d + " #" + c.spriteId : "nothing"));
			if (vm.debug && !c) logMouseChain(e.target as DisplayObject);
			if (vm.debug && !c && root.stage)
			{
				try
				{
					var under:Array = root.stage.getObjectsUnderPoint(new Point(e.stageX, e.stageY));
					for each (var u:DisplayObject in under)
					{
						var path:String = "";
						for (var q:DisplayObject = u; q && q != root.parent; q = q.parent)
						{
							var qc:AClip = wrappers[q];
							path = q.name + (q is InteractiveObject ? ((q as InteractiveObject).mouseEnabled ? "+" : "-") : "") + (qc ? "#" + qc.spriteId + (isMouseTarget(qc) ? "T" : "") : "") + "/" + path;
						}
						vm.log("avm1:   under: " + path + " " + getQualifiedClassName(u) + " vis " + u.visible);
						if (u.parent && u.parent.name == "m_raceEngine")
						{
							var kl:String = "";
							for (var ki:int = 0; ki < u.parent.numChildren; ki++) { var kd:DisplayObject = u.parent.getChildAt(ki); kl += " " + (kd ? kd.name + ":" + getQualifiedClassName(kd) + (kd is InteractiveObject ? ((kd as InteractiveObject).mouseEnabled ? "+" : "-") : "") : "null"); }
							vm.log("avm1:   kids:" + kl);
						}
					}
				}
				catch (ue:Error) { vm.log("avm1:   under: " + ue); }
			}
			if (c)
			{
				if (hover != c)
				{
					if (hover) mouseAction(hover, EV_ROLLOUT, BC_ROLLOUT, "onRollOut");
					hover = c;
					mouseAction(c, EV_ROLLOVER, BC_ROLLOVER, "onRollOver");
				}
				pressed = c;
				mouseAction(c, EV_PRESS, BC_PRESS, "onPress");
			}
		}

		private function onMouseUp(e:MouseEvent):void
		{
			// one failing clip must not stop the rest of the frame (or the whole player)
			inInput = true;
			try { onMouseUpBody(e); } catch (err:Error) { vm.handlerError("onMouseUp", err); }
			inInput = false;
		}

		private function onMouseUpBody(e:MouseEvent):void
		{
			if (foreignTarget && e.target == foreignTarget) return;
			if (paused || !root) return;
			if (!inMovie(e) && !pressed) return;
			fireAll(EV_MOUSEUP);
			vm.lib.mouseEvent("onMouseUp");
			callAll("onMouseUp");
			var p:AClip = pressed;
			pressed = null;
			if (!p) return;
			var t:DisplayObject = e.target as DisplayObject;
			var inside:Boolean = false;
			var d:DisplayObject = t;
			var guard:int = 0;
			while (d && guard++ < 60)
			{
				if (d == p.d) { inside = true; break; }
				d = d.parent;
			}
			if (inside) mouseAction(p, EV_RELEASE, BC_RELEASE, "onRelease");
			else
			{
				mouseAction(p, EV_RELEASEOUTSIDE, BC_RELEASEOUTSIDE, "onReleaseOutside");
				if (hover == p) { mouseAction(p, EV_ROLLOUT, BC_ROLLOUT, "onRollOut"); hover = null; }
			}
		}

		private function onMouseMove(e:MouseEvent):void
		{
			// one failing clip must not stop the rest of the frame (or the whole player)
			inInput = true;
			try { onMouseMoveBody(e); } catch (err:Error) { vm.handlerError("onMouseMove", err); }
			inInput = false;
		}

		private function onMouseMoveBody(e:MouseEvent):void
		{
			if (foreignTarget && e.target == foreignTarget) return;
			if (paused || !root || !inMovie(e)) return;
			fireAll(EV_MOUSEMOVE);
			vm.lib.mouseEvent("onMouseMove");
			callAll("onMouseMove");
			var c:AClip = handlerClip(e.target as DisplayObject);
			if (c != hover && !pressed)
			{
				if (hover) mouseAction(hover, EV_ROLLOUT, BC_ROLLOUT, "onRollOut");
				hover = c;
				if (c) mouseAction(c, EV_ROLLOVER, BC_ROLLOVER, "onRollOver");
			}
		}

		// ================================================================= keys

		private function onKeyDown(e:KeyboardEvent):void
		{
			// one failing clip must not stop the rest of the frame (or the whole player)
			inInput = true;
			try { onKeyDownBody(e); } catch (err:Error) { vm.handlerError("onKeyDown", err); }
			inInput = false;
		}

		private function onKeyDownBody(e:KeyboardEvent):void
		{
			if (paused) return;
			vm.lib.setKey(e.keyCode, e.charCode, true);
			fireAll(EV_KEYDOWN);
			vm.lib.keyEvent("onKeyDown");
			// a held key repeats (keyboard / gamepad auto-repeat): keyPress handlers fire again, as in Flash
			var kp:int = keyPressCode(e.keyCode, e.charCode);
			if (kp > 0)
			{
				fireAll(EV_KEYPRESS, kp);
				buttonKeyPress(kp);
			}
		}

		private function onKeyUp(e:KeyboardEvent):void
		{
			// one failing clip must not stop the rest of the frame (or the whole player)
			inInput = true;
			try { onKeyUpBody(e); } catch (err:Error) { vm.handlerError("onKeyUp", err); }
			inInput = false;
		}

		private function onKeyUpBody(e:KeyboardEvent):void
		{
			vm.lib.setKey(e.keyCode, e.charCode, false);
			if (paused) return;
			fireAll(EV_KEYUP);
			vm.lib.keyEvent("onKeyUp");
		}

		/** on(keyPress "<Left>") codes */
		private static function keyPressCode(keyCode:int, charCode:int):int
		{
			switch (keyCode)
			{
				case 37: return 1;  case 39: return 2;  case 36: return 3;  case 35: return 4;
				case 45: return 5;  case 46: return 6;  case 8: return 8;   case 13: return 13;
				case 38: return 14; case 40: return 15; case 33: return 16; case 34: return 17;
				case 9: return 18;  case 27: return 19;
			}
			return charCode > 31 ? charCode : 0;
		}

		private function buttonKeyPress(kp:int):void
		{
			for each (var c:AClip in clips.concat())
			{
				if (!c.isButton || !c.loaded) continue;
				var conds:Array = data.buttonConds[c.spriteId];
				if (!conds) continue;
				for each (var bc:Object in conds)
				{
					if (bc.key == kp)
					{
						var owner:AClip = parentOf(c) || rootClip;
						vm.runOn(owner, bc.code, owner);
					}
				}
			}
		}

		// ================================================================= text fields

		private function syncText(c:AClip):void
		{
			if (!c.textVar || !(c.d is TextField)) return;
			var owner:AClip = parentOf(c) || rootClip;
			var ctx:Ctx = new Ctx();
			ctx.scope = [vm.global, owner];
			ctx.target = ctx.baseTarget = owner;
			ctx.thisObj = owner;
			var v:*;
			try { v = vm.getVariable(ctx, c.textVar.v); } catch (e:Error) { return; }
			var s:String = v === undefined ? null : vm.toStr(v);
			if (s === null) return;
			if (s == c.lastText) return;
			c.lastText = s;
			var tf:TextField = c.d as TextField;
			try
			{
				if (c.textVar.html) tf.htmlText = s;
				else tf.text = s;
			}
			catch (e2:Error) {}
		}

		private function onTextInput(e:Event):void
		{
			// one failing clip must not stop the rest of the frame (or the whole player)
			try { onTextInputBody(e); } catch (err:Error) { vm.handlerError("onTextInput", err); }
		}

		private function onTextInputBody(e:Event):void
		{
			var c:AClip = wrappers[e.currentTarget];
			if (!c || !c.textVar) return;
			var owner:AClip = parentOf(c) || rootClip;
			var ctx:Ctx = new Ctx();
			ctx.scope = [vm.global, owner];
			ctx.target = ctx.baseTarget = owner;
			ctx.thisObj = owner;
			c.lastText = (c.d as TextField).text;
			vm.setVariable(ctx, c.textVar.v, c.lastText);
		}

		// ================================================================= hierarchy

		public function parentOf(c:AClip):AClip
		{
			if (!c || c == rootClip || !c.d) return null;
			var p:DisplayObjectContainer = c.d.parent;
			if (!p || p == stage || !(p is MovieClip)) return p == root ? rootClip : null;
			if (root && !(root == p || root.contains(p))) return null;
			return clipOf(p);
		}

		public function targetPath(c:AClip, dot:Boolean):String
		{
			if (!c) return "";
			var names:Array = [];
			var cur:AClip = c;
			var guard:int = 0;
			while (cur && cur != rootClip && guard++ < 60)
			{
				names.unshift(nameOf(cur));
				cur = parentOf(cur);
			}
			if (dot) return "_level0" + (names.length ? "." + names.join(".") : "");
			return "/" + names.join("/");
		}

		/** child clip by instance name (target paths look at children before variables) */
		public function childClip(c:AClip, name:String):AClip
		{
			var ch:DisplayObject = childByName(c, name);
			if (ch && (ch is MovieClip || ch is SimpleButton || ch is TextField)) return clipOf(ch);
			return null;
		}

		/** clips renamed by code while AIR keeps their timeline name (see rename) */
		private var renamedCount:int = 0;

		public function nameOf(c:AClip):String
		{
			return c.altName != null ? c.altName : c.d.name;
		}

		/**
		 * this._name = "ball1": AIR refuses to rename an object placed by the timeline (#2078), but
		 * old games do it all the time in onClipEvent(load). Keep the new name ourselves.
		 */
		private function rename(c:AClip, n:String):void
		{
			if (c == rootClip) return;
			noteCodeName(n);
			try
			{
				c.d.name = n;
				if (c.altName != null) { c.altName = null; renamedCount--; }
				return;
			}
			catch (e:Error) {}
			if (c.altName == null) renamedCount++;
			c.altName = n;
			var ak:String = vm.version < 7 ? n.toLowerCase() : n;
			var list:Array = altByName[ak];
			if (!list) altByName[ak] = list = [];
			if (list.indexOf(c) < 0) list.push(c);
		}

		/** renamed clips by their new name (lower case for SWF 6 and older) */
		private var altByName:Object = {};

		private function childByName(c:AClip, name:String):DisplayObject
		{
			var cont:DisplayObjectContainer = c.d as DisplayObjectContainer;
			if (!cont || c.isButton) return null;
			var d:DisplayObject = null;
			// getChildByName goes through all the children: skip it for names no clip has
			// ("gotoAndStop", "speed"...), which is most look-ups
			if (!data.namesUnsure && data.instanceNames[name] !== true && codeNames[name] !== true
				&& (vm.version >= 7 || (data.instanceNames[lower(name)] !== true && codeNames[lower(name)] !== true))
				&& name.indexOf("instance") != 0) return null;
			try { d = cont.getChildByName(name); } catch (e:Error) {}
			if (renamedCount > 0)
			{
				// a renamed child answers only to its new name
				var dw:AClip = d ? wrappers[d] : null;
				if (dw && dw.altName != null && dw.altName != name) d = null;
				if (!d)
				{
					var al:Array = altByName[vm.version < 7 ? name.toLowerCase() : name] as Array;
					if (al)
					{
						for each (var kw:AClip in al)
						{
							if (kw.d.parent == cont && kw.altName != null && (kw.altName == name || (vm.version < 7 && kw.altName.toLowerCase() == name.toLowerCase()))) return kw.d;
						}
					}
				}
			}
			if (d) return d;
			if (vm.version < 7)
			{
				var lc:String = name.toLowerCase();
				for (var i:int = 0; i < cont.numChildren; i++)
				{
					var ch:DisplayObject = cont.getChildAt(i);
					if (ch && ch.name && ch.name.toLowerCase() == lc) return ch;
				}
			}
			return null;
		}

		public function childNames(c:AClip):Array
		{
			var res:Array = [];
			var cont:DisplayObjectContainer = c.d as DisplayObjectContainer;
			if (!cont || c.isButton) return res;
			for (var i:int = cont.numChildren - 1; i >= 0; i--)
			{
				var ch:DisplayObject = cont.getChildAt(i);
				var chw:AClip = wrappers[ch];
				var chn:String = chw ? nameOf(chw) : ch.name;
				// (unnamed ones are "instanceN" in Flash too, and for..in lists them)
				if ((ch is MovieClip || ch is SimpleButton || ch is TextField) && chn) res.push(chn);
			}
			return res;
		}

		// ================================================================= properties

		private static const INDEXED:Array = ["_x", "_y", "_xscale", "_yscale", "_currentframe", "_totalframes",
			"_alpha", "_visible", "_width", "_height", "_rotation", "_target", "_framesloaded", "_name",
			"_droptarget", "_url", "_highquality", "_focusrect", "_soundbuftime", "_quality", "_xmouse", "_ymouse"];

		public function getIndexed(c:AClip, i:int):*
		{
			return i >= 0 && i < INDEXED.length ? getProp(c, INDEXED[i]) : undefined;
		}

		public function setIndexed(c:AClip, i:int, v:*):void
		{
			if (i >= 0 && i < INDEXED.length) setProp(c, INDEXED[i], v);
		}

		private static const NONE:Object = {};

		public function hasProp(c:AClip, name:String):Boolean
		{
			if (c.findHolder(vm.key(name))) return true;
			if (childByName(c, name)) return true;
			return builtinGet(c, name.toLowerCase()) !== NONE;
		}

		public function getProp(c:AClip, name:String):*
		{
			var v:* = lookupProp(c, name);
			return v === NONE ? undefined : v;
		}

		/** lower-case names, computed once (property names repeat all the time) */
		private static var lowerCache:Object = {};

		private static function lower(name:String):String
		{
			var l:* = lowerCache[name];
			if (l === undefined) { l = name.toLowerCase(); lowerCache[name] = l; }
			return l;
		}

		/** the value of a clip's property, or ABSENT when the clip has none of that name (scope lookups) */
		public function lookupProp(c:AClip, name:String):*
		{
			var k:String = vm.key(name);
			var own:* = c.lookup(k);
			if (own !== AObject.ABSENT) return own;
			var b:*;
			// "_x", "_parent", ...: built-ins first, no need to look for a child of that name
			var builtinDone:Boolean = name.charCodeAt(0) == 95;
			if (builtinDone)
			{
				b = builtinGet(c, lower(name));
				if (b !== NONE) return b;
			}
			var ch:DisplayObject = childByName(c, name);
			if (ch && (ch is MovieClip || ch is SimpleButton || ch is TextField)) return clipOf(ch);
			if (!builtinDone)
			{
				b = builtinGet(c, lower(name));
				if (b !== NONE) return b;
			}
			var pv:* = vm.objFind(c, name);
			if (pv !== AObject.ABSENT) return pv;
			return ch ? undefined : NONE;
		}

		public static function get ABSENT():Object { return NONE; }

		private function builtinGet(c:AClip, lc:String):*
		{
			var d:DisplayObject = c.d;
			var mc:MovieClip = d as MovieClip;
			switch (lc)
			{
				case "_x": return d.x;
				case "_y": return d.y;
				case "_xscale": return d.scaleX * 100;
				case "_yscale": return d.scaleY * 100;
				case "_rotation": return d.rotation;
				case "_alpha": return d.alpha * 100;
				case "_visible": return d.visible;
				case "_width": return d.width;
				case "_height": return d.height;
				case "_currentframe": return mc ? (c.driveFrame > 0 ? c.driveFrame : mc.currentFrame) : 1;
				case "_totalframes": return mc ? mc.totalFrames : 1;
				case "_framesloaded": return mc ? mc.totalFrames : 1;
				case "_name": return c == rootClip ? "" : nameOf(c);
				case "_parent": return parentOf(c);
				case "_root": case "_level0": return rootClip;
				case "_target": return targetPath(c, false);
				case "_url": return "";
				case "_xmouse": return d.mouseX;
				case "_ymouse": return d.mouseY;
				case "_droptarget": return "";
				case "_quality": return "HIGH";
				case "_highquality": return 1;
				case "_focusrect": return true;
				case "_soundbuftime": return 5;
				case "_lockroot": return false;
			}
			if (c.isText)
			{
				var tf:TextField = d as TextField;
				switch (lc)
				{
					case "text": return tf.text;
					case "htmltext": return tf.htmlText;
					case "textcolor": return tf.textColor;
					case "textwidth": return tf.textWidth;
					case "textheight": return tf.textHeight;
					case "length": return tf.length;
					case "maxchars": return tf.maxChars;
					case "type": return tf.type;
					case "selectable": return tf.selectable;
					case "multiline": return tf.multiline;
					case "wordwrap": return tf.wordWrap;
					case "autosize": return tf.autoSize;
					case "border": return tf.border;
					case "background": return tf.background;
					case "backgroundcolor": return tf.backgroundColor;
					case "bordercolor": return tf.borderColor;
					case "password": return tf.displayAsPassword;
					case "variable": return c.textVar ? c.textVar.v : null;
					case "html": return c.textVar ? c.textVar.html : false;
					case "embedfonts": return tf.embedFonts;
					case "scroll": return tf.scrollV;
					case "maxscroll": return tf.maxScrollV;
					case "bottomscroll": return tf.bottomScrollV;
					case "hscroll": return tf.scrollH;
					case "maxhscroll": return tf.maxScrollH;
				}
			}
			return NONE;
		}

		public function setProp(c:AClip, name:String, v:*):void
		{
			var lc:String = name.toLowerCase();
			var d:DisplayObject = c.d;
			var num:Number;
			try
			{
				switch (lc)
				{
					case "_x": num = vm.toNumber(v); if (!isNaN(num)) d.x = num; return;
					case "_y": num = vm.toNumber(v); if (!isNaN(num)) d.y = num; return;
					case "_xscale": num = vm.toNumber(v); if (!isNaN(num)) d.scaleX = num / 100; return;
					case "_yscale": num = vm.toNumber(v); if (!isNaN(num)) d.scaleY = num / 100; return;
					case "_rotation": num = vm.toNumber(v); if (!isNaN(num)) d.rotation = num; return;
					case "_alpha": num = vm.toNumber(v); if (!isNaN(num)) d.alpha = num / 100; return;
					case "_visible": d.visible = vm.toBoolean(v); return;
					case "_width": num = vm.toNumber(v); if (!isNaN(num) && num >= 0) d.width = num; return;
					case "_height": num = vm.toNumber(v); if (!isNaN(num) && num >= 0) d.height = num; return;
					case "_name": rename(c, vm.toStr(v)); return;
					case "_currentframe": case "_totalframes": case "_framesloaded": case "_target":
					case "_url": case "_xmouse": case "_ymouse": case "_droptarget": case "_parent": case "_root":
						return; // read-only
					case "_quality": case "_highquality": case "_focusrect": case "_soundbuftime":
						return;
				}
				if (c.isText)
				{
					var tf:TextField = d as TextField;
					switch (lc)
					{
						case "text": tf.text = vm.toStr(v); c.lastText = tf.text; return;
						case "htmltext": tf.htmlText = vm.toStr(v); return;
						case "textcolor": tf.textColor = uint(vm.toNumber(v)); return;
						case "maxchars": tf.maxChars = vm.toInt32(v); return;
						case "type": tf.type = vm.toStr(v) == "input" ? TextFieldType.INPUT : TextFieldType.DYNAMIC; return;
						case "selectable": tf.selectable = vm.toBoolean(v); return;
						case "multiline": tf.multiline = vm.toBoolean(v); return;
						case "wordwrap": tf.wordWrap = vm.toBoolean(v); return;
						case "autosize":
							var asz:String = vm.toStr(v);
							tf.autoSize = asz == "true" || asz == "left" ? TextFieldAutoSize.LEFT : asz == "center" ? TextFieldAutoSize.CENTER
								: asz == "right" ? TextFieldAutoSize.RIGHT : TextFieldAutoSize.NONE;
							return;
						case "border": tf.border = vm.toBoolean(v); return;
						case "background": tf.background = vm.toBoolean(v); return;
						case "backgroundcolor": tf.backgroundColor = uint(vm.toNumber(v)); return;
						case "bordercolor": tf.borderColor = uint(vm.toNumber(v)); return;
						case "password": tf.displayAsPassword = vm.toBoolean(v); return;
						case "variable":
							c.textVar = v ? { v: vm.toStr(v), html: false } : null;
							c.lastText = null;
							return;
						case "html": if (c.textVar) c.textVar.html = vm.toBoolean(v); return;
						case "embedfonts": tf.embedFonts = vm.toBoolean(v); return;
						case "scroll": tf.scrollV = vm.toInt32(v); return;
						case "hscroll": tf.scrollH = vm.toInt32(v); return;
					}
				}
			}
			catch (e:Error)
			{
				return;
			}
			vm.objSet(c, name, v);
			if (MOUSE_HANDLERS[lc] && c.d is MovieClip)
				(c.d as MovieClip).mouseEnabled = isMouseTarget(c);
		}

		private static const MOUSE_HANDLERS:Object = { onpress: 1, onrelease: 1, onreleaseoutside: 1,
			onrollover: 1, onrollout: 1, ondragover: 1, ondragout: 1, enabled: 1 };

		// ================================================================= timeline

		private function mcOf(c:AClip):MovieClip
		{
			return c ? c.d as MovieClip : null;
		}

		// AIR postpones a goto made from inside a frame script until the script ends, so a
		// following play()/stop() (AS1 "gotoAndStop(n); play();", what Flash 4/5 compiled
		// gotoAndPlay into) would run first and then get undone. Redo the goto with the
		// wanted play state instead.
		public function play(c:AClip):void
		{
			var m:MovieClip = mcOf(c);
			if (vm.debug) dbg("play", c);
			if (!m) return;
			if (c.driveFrame > 0) { c.drivePlaying = true; return; }
			if (hasPending(c, m)) { try { m.gotoAndPlay(c.pendingGoto); } catch (e:Error) {} }
			else m.play();
		}

		private static function clipPlaying(m:MovieClip):Boolean
		{
			try { return m["isPlaying"] === true; } catch (e:Error) {}
			return false;
		}

		/**
		 * The clip reached a frame whose script AIR hasn't run yet (AIR runs it later than Flash
		 * would, after mouse and key events). A stop()/goto from such an event must come after
		 * that script, as in Flash: run it now; AIR's own call for it is skipped.
		 */
		/** inside a mouse / key event handler */
		private var inInput:Boolean = false;

		private function flushFrameScript(c:AClip, m:MovieClip):void
		{
			if (!inInput || !c || !m || c.spriteId < 0 || !c.loaded) return;
			if (c.gotoTick == tick) return; // moved there by code: that frame's code is queued
			var f:int = m.currentFrame;
			if (c.lastRunFrame == f) return;
			var frames:Object = data.frameActions[c.spriteId];
			if (!frames || !frames[f]) return;
			if (!childrenMade(m)) return; // its clips aren't made yet: AIR runs it when they are
			runFrame(c, f);
			c.initFrame = f;
			c.initTick = tick;
		}

		public function stop(c:AClip):void
		{
			var m:MovieClip = mcOf(c);
			if (vm.debug) dbg("stop", c);
			if (!m) return;
			c.codeStopTick = tick;
			if (inInput)
			{
				// AIR may still run this frame's code after the event (Flash ran it before): if that
				// code starts the clip again, the stop must win, as in Flash
				c.stopFrame = m.currentFrame;
				c.stopTick = tick;
			}
			if (c.driveFrame > 0) { c.drivePlaying = false; return; }
			if (hasPending(c, m)) { try { m.gotoAndStop(c.pendingGoto); } catch (e:Error) {} }
			else m.stop();
		}

		private function hasPending(c:AClip, m:MovieClip):Boolean
		{
			if (c.pendingGoto === null || c.pendingTick != tick) return false;
			var f:int = c.pendingGoto is String ? labelFrame(m, c.pendingGoto) : int(c.pendingGoto);
			if (m.currentFrame == f) { c.pendingGoto = null; return false; }
			return true;
		}

		private var dbgCount:int = 0;

		private function dbg(what:String, c:AClip, extra:String = ""):void
		{
			if (dbgCount++ > vm.debugLimit && c != rootClip) return;
			var m:MovieClip = mcOf(c);
			vm.log("avm1: " + what + " " + (c ? targetPath(c, true) + " #" + c.spriteId + (m ? " at " + m.currentFrame + "/" + m.totalFrames : " (not a clip)") : "null") + extra);
		}
		public function nextFrame(c:AClip):void
		{
			var m:MovieClip = mcOf(c);
			if (!m) return;
			if (c.driveFrame > 0) { var nf:int = c.driveFrame + 1; releaseDrive(c); gotoFrame(c, Math.min(nf, m.totalFrames), false); return; }
			var before:int = m.currentFrame;
			m.nextFrame();
			queueFrameScript(c, m, Math.min(before + 1, m.totalFrames), before);
		}

		public function prevFrame(c:AClip):void
		{
			var m:MovieClip = mcOf(c);
			if (!m) return;
			if (c.driveFrame > 0) { var pf:int = c.driveFrame - 1; releaseDrive(c); gotoFrame(c, Math.max(pf, 1), false); return; }
			var before:int = m.currentFrame;
			m.prevFrame();
			queueFrameScript(c, m, Math.max(before - 1, 1), before);
		}

		// ----------------------------------------------------------------- goto -> frame script
		// In Flash the script of the frame a goto lands on runs right after the current script.
		// AIR runs it late or (for a goto from inside a frame script) not at all, so a clip that
		// does "gotoAndStop(level + 1)" in frame 1 never set up its level. Run it ourselves: right
		// after the code that made the goto, or at the end of the frame when AIR did the goto
		// only after that code.

		private var gotoQueue:Array = [];

		private function queueFrameScript(c:AClip, m:MovieClip, want:int, before:int):void
		{
			if (!c || c.spriteId < 0 || want < 1) return;
			c.gotoTick = tick;
			if (want == before) return;
			var acts:Object = data.frameActions[c.spriteId];
			var snds:Object = data.frameSounds[c.spriteId];
			if (!(acts && acts[want]) && !(snds && snds[want])) return;
			// every goto queues its frame's code, in order, like Flash ("gotoAndStop(a); gotoAndStop(b)"
			// runs a's code and then b's)
			if (gotoQueue.length > 200) return;
			gotoQueue.push({ c: c, f: want });
		}

		/** run the queued frame scripts whose goto has happened; final: end of the frame */
		private var drainDepth:int = 0;

		public function drainGotos(final:Boolean):void
		{
			if (drainDepth > 16) { gotoQueue = []; return; } // frames sending each other back and forth
			drainDepth++;
			try { drainOnce(final); } finally { drainDepth--; }
		}

		private function drainOnce(final:Boolean):void
		{
			for (var pass:int = 0; pass < 8 && gotoQueue.length; pass++)
			{
				var list:Array = gotoQueue;
				gotoQueue = [];
				// a clip's gotos have happened when it is on the frame of its last one (AIR postpones
				// gotos made inside frame scripts; those wait for the end of the frame)
				var lastF:Dictionary = new Dictionary();
				var q:Object;
				for each (q in list) if (!q.load) lastF[q.c] = q.f;
				var ready:Array = [];
				var keep:Array = [];
				for each (q in list)
				{
					if (q.load) { if (q.c.loaded && q.c.loadQueued) ready.push(q); continue; }
					var m:MovieClip = mcOf(q.c);
					if (!m || !q.c.loaded) continue;
					// AIR has moved the playhead, but the new frame's clips aren't made yet (a goto
					// from a key / mouse handler): the code would not find them (engine.player...).
					// AIR runs the frame's script itself once they exist.
					if (!childrenMade(m)) { keep.push(q); continue; }
					if (m.currentFrame == lastF[q.c]) ready.push(q);
					else if (final) { if (m.currentFrame == q.f) ready.push(q); } // AIR moved it elsewhere
					else keep.push(q);
				}
				gotoQueue = keep.concat(gotoQueue);
				if (!ready.length) break;
				for each (q in ready)
				{
					var c:AClip = q.c;
					if (q.load)
					{
						if (c.loadQueued && c.loaded) { loadVia = "drain"; loadClip(c); }
						continue;
					}
					if (c.loadQueued) continue; // its load comes first and runs this frame's code
					if (c.lastRunFrame == q.f && c.lastRunTick == tick) continue; // AIR ran it
					// queued twice (by the goto and by AIR): the first run moved the clip on already
					// (candygirl's game over: frame 6's nextFrame(), then frame 6 again from frame 7)
					var dm:MovieClip = mcOf(c);
					if (dm && dm.currentFrame != q.f && c.ranFrames && c.ranFrames[q.f] == tick) continue;
					rfVia = "drain"; runFrame(c, q.f);
					var cm:MovieClip = mcOf(c);
					if (cm && cm.currentFrame == q.f)
					{
						c.initFrame = q.f;
						c.initTick = tick;
					}
				}
			}
		}

		/** false while AIR is still building the frame a goto went to (a child slot is null) */
		private static function childrenMade(m:MovieClip):Boolean
		{
			try
			{
				for (var i:int = 0; i < m.numChildren; i++) if (!m.getChildAt(i)) return false;
			}
			catch (e:Error) { return false; }
			return true;
		}

		/** the clip whose frame script is running now (AIR's call, or a driven frame) */
		private var airScriptClip:AClip;

		// ----------------------------------------------------------------- driven loops
		// A clip looping "frame N: gotoAndPlay(N-1)" over frames that look the same: AIR's playhead
		// stays stopped on N and we step through the frames' scripts, one frame per tick, as Flash.

		private var drives:Array = [];
		/** test switch */
		public static var driveLoops:Boolean = true;
		/** frame scripts to run after the current code: { c, f } */
		private var driveRuns:Array = [];

		private function runDriveScripts():void
		{
			for (var guard:int = 0; guard < 50 && driveRuns.length; guard++)
			{
				var r:Object = driveRuns.shift();
				runDriven(r.c, r.f);
			}
		}

		private function runDriven(c:AClip, f:int):void
		{
			if (!c.alive || c.driveFrame <= 0) return;
			var outer:AClip = airScriptClip;
			airScriptClip = c;
			try { runFrame(c, f); } finally { airScriptClip = outer; }
		}

		private function releaseDrive(c:AClip):void
		{
			c.driveFrame = 0;
			c.drivePlaying = false;
			var i:int = drives.indexOf(c);
			if (i >= 0) drives.splice(i, 1);
		}

		/** one step for each driven clip (FRAME_CONSTRUCTED, when AIR would run frame scripts) */
		private function stepDrives():void
		{
			for each (var c:AClip in drives.concat())
			{
				var m:MovieClip = mcOf(c);
				if (!m || !c.alive || !m.stage) { releaseDrive(c); continue; }
				if (!c.drivePlaying) continue;
				var next:int = c.driveFrame + 1;
				if (next > c.driveTop)
				{
					// past the loop: AIR's playhead takes over again
					var top:int = c.driveTop;
					releaseDrive(c);
					try { m.gotoAndPlay(top < m.totalFrames ? top + 1 : 1); } catch (e:Error) {}
					continue;
				}
				c.driveFrame = next;
				runDriven(c, next);
				runDriveScripts();
			}
		}
		private var loggedRootFrame:int = -1;

		private function onExitFrame(e:Event):void
		{
			if (paused) return;
			// the main timeline's frame, always (the detailed log stops after a while)
			if (vm.debug && root && root.currentFrame != loggedRootFrame)
			{
				loggedRootFrame = root.currentFrame;
				var kids:int = 0;
				try { kids = root.numChildren; } catch (ke:Error) {}
				vm.log("avm1: main timeline on frame " + loggedRootFrame + "/" + root.totalFrames + (root.currentLabel ? " \"" + root.currentLabel + "\"" : "") + ", " + kids + " objects, playing " + root.isPlaying);
			}
			if (vm.watch && vm.watch["@goto"]) for each (var wc:AClip in clips) if (wc.spriteId == int(vm.watch["@goto"])) vm.log("avm1: @exit #" + wc.spriteId + " " + wc.d.name + " at " + (wc.d as MovieClip).currentFrame + " playing " + (wc.d as MovieClip).isPlaying + " q " + gotoQueue.length + " tick " + tick);
			if (vm.running) return; // a goto inside the game's code: afterCode does it when the code ends
			if (frameStarted) runEnterFrames(); // (no FRAME_CONSTRUCTED this frame)
			try
			{
				if (gotoQueue.length) drainGotos(true);
				if (gotoQueue.length) drainGotos(true);
				if (kidOwners.length) flushAllKids();
				fixDynOrder();
			}
			catch (err:Error) { vm.handlerError("onExitFrame", err); }
		}

		public function gotoFrame(c:AClip, frame:*, andPlay:Boolean):void
		{
			var m:MovieClip = mcOf(c);
			if (vm.debug) dbg(andPlay ? "gotoAndPlay" : "gotoAndStop", c, " -> " + frame);
			if (!m) return;
			try
			{
				if (frame is String)
				{
					var n:Number = Number(frame);
					if (frame != "" && !isNaN(n)) frame = int(n);
					else if (labelFrame(m, frame) < 0) return; // unknown label: Flash ignores it
				}
				if (!(frame is String))
				{
					var f:int = int(frame);
					if (f < 1) f = 1;
					if (f > m.totalFrames) f = m.totalFrames;
					frame = f;
				}
				var before:int = m.currentFrame;
				var wantF:int = frame is String ? labelFrame(m, frame) : int(frame);
				if (c.driveFrame > 0) before = c.driveFrame;
				if (driveLoops && c == airScriptClip && andPlay && wantF >= 1 && wantF < before && data.sameLook(c.spriteId, wantF, Math.max(before, c.driveTop)))
				{
					// "frame 37: gotoAndPlay(36)" from the clip's own frame script. AIR would postpone
					// the goto and then skip the clip's next step, so such loops ran at half speed.
					// The frames look the same, so play them ourselves without moving AIR's playhead.
					if (c.driveFrame <= 0) { c.driveTop = before; m.stop(); if (drives.indexOf(c) < 0) drives.push(c); }
					c.driveFrame = wantF;
					c.drivePlaying = true;
					c.gotoTick = tick;
					driveRuns.push({ c: c, f: wantF });
					c.pendingGoto = null;
					return;
				}
				if (c.driveFrame > 0) releaseDrive(c);
				before = m.currentFrame;
				if (!andPlay && wantF == before && wantF >= 1)
				{
					// the frame it is on: only a stop, as in Flash. (AIR's goto to the current frame
					// left the clips it is just making stopped — candygirl's START countdown, put on
					// txt_set's frame 1 while code said txt_set.gotoAndStop(1).)
					m.stop();
					c.codeStopTick = tick;
					if (vm.watch && vm.watch["@goto"]) vm.log("avm1: @goto #" + c.spriteId + " same frame " + wantF + ": stop");
					c.pendingGoto = null;
					return;
				}
				if (andPlay) m.gotoAndPlay(frame);
				else { m.gotoAndStop(frame); c.codeStopTick = tick; }
				var want:int = frame is String ? labelFrame(m, frame) : int(frame);
				queueFrameScript(c, m, want, before);
				if (vm.watch && vm.watch["@goto"]) vm.log("avm1: @goto #" + c.spriteId + " " + before + "->" + want + " now " + m.currentFrame + " running " + vm.running + " tick " + tick);
				if (m.currentFrame != want) { c.pendingGoto = frame; c.pendingTick = tick; }
				else c.pendingGoto = null;

			}
			catch (e:Error) {}
		}

		/** unloadMovie(): the clip stays, but empty (no pictures, no timeline) */
		public function unload(c:AClip):void
		{
			if (!c || c == rootClip) return;
			var m:MovieClip = c.d as MovieClip;
			if (!m) { if (c.d) c.d.visible = false; return; }
			if (c.driveFrame > 0) releaseDrive(c);
			c.unloaded = true;
			try { m.stop(); } catch (e:Error) {}
			try { m.graphics.clear(); } catch (e2:Error) {}
			try { while (m.numChildren) m.removeChildAt(m.numChildren - 1); } catch (e3:Error) {}
			fireClip(c, EV_UNLOAD);
		}

		public function labelFrame(m:MovieClip, label:String):int
		{
			var lc:String = label.toLowerCase();
			try
			{
				for each (var fl:FrameLabel in m.currentLabels)
				{
					if (fl.name == label || fl.name.toLowerCase() == lc) return fl.frame;
				}
			}
			catch (e:Error) {}
			return -1;
		}

		/** call("frame"): run a frame's code without going there */
		public function callFrame(c:AClip, frame:String):void
		{
			var m:MovieClip = mcOf(c);
			if (!m) return;
			var n:Number = Number(frame);
			var f:int = frame != "" && !isNaN(n) ? int(n) : labelFrame(m, frame);
			var frames:Object = data.frameActions[c.spriteId];
			if (f < 1 || !frames || !frames[f]) return;
			for each (var code:ByteArray in frames[f]) vm.runOn(c, code);
		}

		// ================================================================= clips made by code

		private function newSymbol(id:int):DisplayObject
		{
			var k:String = data.kinds[id];
			var cls:String = k == "sprite" ? AbcGen.SPRITE + id : k == "button" ? AbcGen.BUTTON + id : null;
			if (!cls) return null;
			try
			{
				var C:Class = domain.getDefinition(cls) as Class;
				return new C() as DisplayObject;
			}
			catch (e:Error)
			{
				vm.warnOnce("can't create symbol " + id + ": " + e.message);
			}
			return null;
		}

		/** names given by code (attachMovie, createEmptyMovieClip, _name =) */
		private var codeNames:Object = {};

		private function noteCodeName(n:String):void
		{
			if (n == null) return;
			try { codeNames[n] = true; codeNames[n.toLowerCase()] = true; } catch (e:Error) { data.namesUnsure = true; }
		}

		private function place(parent:AClip, d:DisplayObject, name:String, depth:Number):AClip
		{
			noteCodeName(name);
			var cont:DisplayObjectContainer = parent ? parent.d as DisplayObjectContainer : null;
			if (!cont) return null;
			try { d.name = name; } catch (e:Error) {}
			// replace what is at that depth
			var old:AClip = atDepth(parent, depth);
			if (old && old.d.parent == cont) cont.removeChild(old.d);
			var idx:int = cont.numChildren;
			for (var i:int = 0; i < cont.numChildren; i++)
			{
				var w:AClip = wrappers[cont.getChildAt(i)];
				if (w && !isNaN(w.dynDepth) && w.dynDepth > depth) { idx = i; break; }
			}
			cont.addChildAt(d, idx);
			var c:AClip = wrap(d);
			c.dynDepth = depth;
			if (depth >= 0) dynParents[cont] = true;
			return c;
		}

		/** containers with clips made by code (attachMovie, duplicateMovieClip...) at depth >= 0 */
		private var dynParents:Dictionary = new Dictionary(true);

		/**
		 * In Flash, clips made by code at depth 0 and up are always above the timeline's own objects
		 * (those live at negative depths). AIR adds new timeline objects on top of everything, so a
		 * duplicated character ended up behind the scene's later frames. Put them back on top.
		 */
		private function fixDynOrder():void
		{
			for (var k:* in dynParents)
			{
				var cont:DisplayObjectContainer = k as DisplayObjectContainer;
				if (!cont) continue;
				var dyn:Array = [];
				var n:int = cont.numChildren;
				for (var i:int = 0; i < n; i++)
				{
					var w:AClip = wrappers[cont.getChildAt(i)];
					if (w && w.dynDepth >= 0) dyn.push(w);
				}
				if (!dyn.length) { delete dynParents[k]; continue; }
				dyn.sortOn("dynDepth", Array.NUMERIC);
				// already the topmost children, in depth order?
				var ok:Boolean = true;
				for (var j:int = 0; j < dyn.length; j++)
				{
					if (cont.getChildIndex((dyn[j] as AClip).d) != n - dyn.length + j) { ok = false; break; }
				}
				if (ok) continue;
				for each (var dc:AClip in dyn)
				{
					try { cont.setChildIndex(dc.d, cont.numChildren - 1); } catch (e:Error) {}
				}
			}
		}

		private function atDepth(parent:AClip, depth:Number):AClip
		{
			var cont:DisplayObjectContainer = parent.d as DisplayObjectContainer;
			if (!cont) return null;
			for (var i:int = 0; i < cont.numChildren; i++)
			{
				var w:AClip = wrappers[cont.getChildAt(i)];
				if (w && w.dynDepth == depth) return w;
			}
			return null;
		}

		private function copyInit(c:AClip, init:*):void
		{
			if (!(init is AObject)) return;
			for each (var k:String in vm.enumerate(init)) setProp(c, k, vm.getMember(init, k));
		}

		public function attach(parent:AClip, linkage:String, name:String, depth:Number, init:*):AClip
		{
			var id:int = data.exportId(linkage);
			if (id < 0) { vm.warnOnce("attachMovie: no symbol \"" + linkage + "\""); return null; }
			var d:DisplayObject = newSymbol(id);
			if (!d) return null;
			var c:AClip = place(parent, d, name, depth);
			if (!c) return null;
			copyInit(c, init);
			initClip(c);
			return c;
		}

		public function duplicate(src:AClip, name:String, depth:Number, init:*):AClip
		{
			if (!src || src == rootClip) return null;
			var parent:AClip = parentOf(src);
			if (!parent) return null;
			var d:DisplayObject = src.spriteId > 0 ? newSymbol(src.spriteId) : (src.d is MovieClip ? new MovieClip() : null);
			if (!d) return null;
			d.transform.matrix = src.d.transform.matrix;
			d.transform.colorTransform = src.d.transform.colorTransform;
			d.visible = src.d.visible;
			var c:AClip = place(parent, d, name, depth);
			if (!c) return null;
			c.events = src.events;
			copyInit(c, init);
			initClip(c);
			return c;
		}

		public function createEmpty(parent:AClip, name:String, depth:Number):AClip
		{
			var c:AClip = place(parent, new MovieClip(), name, depth);
			if (c) initClip(c);
			return c;
		}

		public function createText(parent:AClip, name:String, depth:Number, x:Number, y:Number, w:Number, h:Number):AClip
		{
			var tf:TextField = new TextField();
			tf.x = x; tf.y = y; tf.width = w; tf.height = h;
			var c:AClip = place(parent, tf, name, depth);
			if (c) initClip(c);
			return c;
		}

		public function remove(c:AClip):void
		{
			if (!c || c == rootClip || isNaN(c.dynDepth)) return;
			if (c.d.parent) c.d.parent.removeChild(c.d);
		}

		public function getDepth(c:AClip):Number
		{
			if (!isNaN(c.dynDepth)) return c.dynDepth;
			if (!c.d.parent) return 0;
			return -16384 + c.d.parent.getChildIndex(c.d);
		}

		public function nextDepth(parent:AClip):Number
		{
			var cont:DisplayObjectContainer = parent.d as DisplayObjectContainer;
			var mx:Number = -1;
			if (cont)
			{
				for (var i:int = 0; i < cont.numChildren; i++)
				{
					var w:AClip = wrappers[cont.getChildAt(i)];
					if (w && !isNaN(w.dynDepth) && w.dynDepth > mx) mx = w.dynDepth;
				}
			}
			return mx + 1;
		}

		public function instanceAt(parent:AClip, depth:Number):AClip
		{
			return atDepth(parent, depth);
		}

		public function swapDepths(c:AClip, target:*):void
		{
			var cont:DisplayObjectContainer = c.d.parent;
			if (!cont) return;
			if (target is AClip)
			{
				var o:AClip = target;
				if (o.d.parent != cont) return;
				var d1:Number = getDepth(c), d2:Number = getDepth(o);
				cont.swapChildren(c.d, o.d);
				c.dynDepth = d2;
				o.dynDepth = d1;
				return;
			}
			var depth:Number = vm.toNumber(target);
			if (isNaN(depth)) return;
			var other:AClip = atDepth(wrap(cont), depth);
			if (other && other != c)
			{
				var mine:Number = getDepth(c);
				cont.swapChildren(c.d, other.d);
				other.dynDepth = mine;
				c.dynDepth = depth;
				return;
			}
			c.dynDepth = depth;
			// (taken out and put back at once: it isn't leaving — onRemoved must not stop and unload
			// it and everything in it; candygirl's START countdown never ran and the game never began)
			moving = true;
			try
			{
				cont.removeChild(c.d);
				var idx:int = cont.numChildren;
				for (var i:int = 0; i < cont.numChildren; i++)
				{
					var w:AClip = wrappers[cont.getChildAt(i)];
					if (w && !isNaN(w.dynDepth) && w.dynDepth > depth) { idx = i; break; }
				}
				cont.addChildAt(c.d, idx);
			}
			finally { moving = false; }
		}

		// ================================================================= geometry & drawing

		/** _root coordinates <-> AS3 global */
		private function rootToGlobal(x:Number, y:Number):Point
		{
			return root.localToGlobal(new Point(x, y));
		}

		public function hitTest(c:AClip, args:Array):Boolean
		{
			try
			{
				if (args.length >= 2)
				{
					var p:Point = rootToGlobal(vm.toNumber(args[0]), vm.toNumber(args[1]));
					var shape:Boolean = vm.toBoolean(args[2]);
					if (shape)
					{
						var hc:Object = hitCacheFor(c);
						if (hc)
						{
							var lp:Point = c.d.globalToLocal(p);
							var bx:int = int((lp.x - hc.x) * hc.s);
							var by:int = int((lp.y - hc.y) * hc.s);
							if (bx < 0 || by < 0 || bx >= hc.bd.width || by >= hc.bd.height) return false;
							return (hc.bd.getPixel32(bx, by) >>> 24) != 0;
						}
					}
					if (!shape) return c.d.hitTestPoint(p.x, p.y, false);
					// Flash tests the outline even when the clip (or its parent) is hidden: games test
					// against an invisible "solid" ground clip. AIR's shape test skips hidden ones.
					var hidden:Array = null;
					for (var hd:DisplayObject = c.d; hd && hd != root.parent; hd = hd.parent)
						if (!hd.visible) { (hidden ||= []).push(hd); hd.visible = true; }
					try { return c.d.hitTestPoint(p.x, p.y, true); }
					finally { for each (hd in hidden) hd.visible = false; }
				}
				var t:AClip = args[0] is AClip ? args[0] : null;
				if (!t && args[0] is String) t = vm.targetClip(ctxFor(c), args[0]);
				return t ? c.d.hitTestObject(t.d) : false;
			}
			catch (e:Error) {}
			return false;
		}

		/** the drawing API was used (pictures cached for hitTest may be out of date) */
		private var drawVersion:int = 0;
		/** clip -> { bd, x, y, s, n, ver } or false (can't be cached); counts before that */
		private var hitCaches:Dictionary = new Dictionary(true);
		private var hitCounts:Dictionary = new Dictionary(true);

		/**
		 * hitTest(x, y, true) on a clip that is only a picture (a level's ground, tested hundreds
		 * of times a frame): look at a bitmap of it instead of AIR's exact test of every outline.
		 */
		private function hitCacheFor(c:AClip):Object
		{
			var hc:* = hitCaches[c];
			var mc:MovieClip = c.d as MovieClip;
			if (hc === false || !mc) return null;
			if (hc && hc.ver == drawVersion && hc.n == mc.numChildren) return hc;
			if (!hc)
			{
				var n:int = (hitCounts[c] | 0) + 1;
				hitCounts[c] = n;
				if (n < 20) return null;
			}
			if (mc.totalFrames > 1 || !onlyPictures(mc, 0)) { hitCaches[c] = false; return null; }
			try
			{
				var r:Rectangle = mc.getBounds(mc);
				if (r.width < 1 || r.height < 1) { hitCaches[c] = false; return null; }
				var sc:Number = 1;
				while ((r.width * sc > 8000 || r.height * sc > 8000 || r.width * r.height * sc * sc > 12000000) && sc > 0.05) sc *= 0.5;
				var w:int = Math.ceil(r.width * sc) + 1, h:int = Math.ceil(r.height * sc) + 1;
				if (hc && hc.bd) (hc.bd as BitmapData).dispose();
				var bd:BitmapData = new BitmapData(w, h, true, 0);
				var vis:Boolean = mc.visible;
				mc.visible = true;
				try { bd.draw(mc, new Matrix(sc, 0, 0, sc, -r.x * sc, -r.y * sc)); }
				finally { mc.visible = vis; }
				hc = { bd: bd, x: r.x, y: r.y, s: sc, n: mc.numChildren, ver: drawVersion };
				hitCaches[c] = hc;
				if (vm.debug) vm.log("avm1: hitTest picture for " + targetPath(c, true) + " " + w + "x" + h);
				return hc;
			}
			catch (e:Error) { hitCaches[c] = false; }
			return null;
		}

		/** nothing in it that can move or change by itself */
		private static function onlyPictures(cont:DisplayObjectContainer, depth:int):Boolean
		{
			if (depth > 20) return false;
			for (var i:int = 0; i < cont.numChildren; i++)
			{
				var ch:DisplayObject = cont.getChildAt(i);
				if (!ch) continue;
				if (ch is MovieClip || ch is SimpleButton || ch is TextField || ch is Loader) return false;
				if (ch is DisplayObjectContainer && !onlyPictures(ch as DisplayObjectContainer, depth + 1)) return false;
			}
			return true;
		}

		public function ctxFor(c:AClip):Ctx
		{
			var ctx:Ctx = new Ctx();
			ctx.scope = [vm.global, c];
			ctx.target = ctx.baseTarget = c;
			ctx.thisObj = c;
			return ctx;
		}

		public function getBounds(c:AClip, target:*):AObject
		{
			var space:DisplayObject = target is AClip ? (target as AClip).d : (target === undefined ? c.d : root);
			var r:Rectangle = c.d.getBounds(space);
			var o:AObject = vm.newObject();
			vm.objSet(o, "xMin", r.left);
			vm.objSet(o, "xMax", r.right);
			vm.objSet(o, "yMin", r.top);
			vm.objSet(o, "yMax", r.bottom);
			return o;
		}

		public function localToGlobal(c:AClip, pt:*, toGlobal:Boolean):void
		{
			if (!(pt is AObject)) return;
			var p:Point = new Point(vm.toNumber(vm.getMember(pt, "x")), vm.toNumber(vm.getMember(pt, "y")));
			var r:Point = toGlobal ? root.globalToLocal(c.d.localToGlobal(p)) : c.d.globalToLocal(root.localToGlobal(p));
			vm.setMember(pt, "x", r.x);
			vm.setMember(pt, "y", r.y);
		}

		public function startDrag(c:AClip, lock:Boolean, rect:Array):void
		{
			var m:MovieClip = mcOf(c);
			if (!m) return;
			if (dragging && dragging != c) stopDrag();
			dragging = c;
			var r:Rectangle = rect ? new Rectangle(rect[0], rect[1], rect[2] - rect[0], rect[3] - rect[1]) : null;
			try { m.startDrag(lock, r); } catch (e:Error) {}
		}

		public function stopDrag():void
		{
			if (!dragging) return;
			var m:MovieClip = mcOf(dragging);
			if (m) try { m.stopDrag(); } catch (e:Error) {}
			dragging = null;
		}

		public function graphicsOf(c:AClip):Graphics
		{
			drawVersion++;
			var m:MovieClip = mcOf(c);
			return m ? m.graphics : null;
		}

		public function gradientFill(c:AClip, args:Array):void
		{
			var g:Graphics = graphicsOf(c);
			if (!g) return;
			try
			{
				var type:String = vm.toStr(args[0]) == "radial" ? GradientType.RADIAL : GradientType.LINEAR;
				var colors:Array = [], alphas:Array = [], ratios:Array = [];
				for each (var col:* in args[1]) colors.push(uint(vm.toNumber(col)));
				for each (var al:* in args[2]) alphas.push(vm.toNumber(al) / 100);
				for each (var ra:* in args[3]) ratios.push(vm.toNumber(ra));
				var mo:* = args[4];
				var m:Matrix = new Matrix();
				if (mo is AObject)
				{
					if (vm.toStr(vm.getMember(mo, "matrixType")) == "box")
						m.createGradientBox(vm.toNumber(vm.getMember(mo, "w")), vm.toNumber(vm.getMember(mo, "h")),
							vm.toNumber(vm.getMember(mo, "r")), vm.toNumber(vm.getMember(mo, "x")), vm.toNumber(vm.getMember(mo, "y")));
					else
						m = new Matrix(vm.toNumber(vm.getMember(mo, "a")), vm.toNumber(vm.getMember(mo, "b")),
							vm.toNumber(vm.getMember(mo, "d")), vm.toNumber(vm.getMember(mo, "e")),
							vm.toNumber(vm.getMember(mo, "g")), vm.toNumber(vm.getMember(mo, "h")));
				}
				g.beginGradientFill(type, colors, alphas, ratios, m);
			}
			catch (e:Error) {}
		}

		// ================================================================= sound / color on clips

		public function setVolume(c:AClip, v:Number):void
		{
			var sp:Sprite = (c ? c.d : root) as Sprite;
			if (!sp) return;
			var st:SoundTransform = sp.soundTransform;
			st.volume = Math.max(0, v / 100);
			try { sp.soundTransform = st; } catch (e:Error) {}
		}

		public function setRGB(c:AClip, rgb:uint):void
		{
			if (!c) return;
			var ct:ColorTransform = c.d.transform.colorTransform;
			ct.color = rgb;
			c.d.transform.colorTransform = ct;
		}

		public function getRGB(c:AClip):uint
		{
			return c ? c.d.transform.colorTransform.color : 0;
		}

		public function setColorTransform(c:AClip, t:*):void
		{
			if (!c || !(t is AObject)) return;
			var ct:ColorTransform = c.d.transform.colorTransform;
			var g:Function = function(n:String, def:Number):Number {
				var v:* = vm.getMember(t, n);
				return v === undefined ? def : vm.toNumber(v);
			};
			ct.redMultiplier = g("ra", ct.redMultiplier * 100) / 100;
			ct.greenMultiplier = g("ga", ct.greenMultiplier * 100) / 100;
			ct.blueMultiplier = g("ba", ct.blueMultiplier * 100) / 100;
			ct.alphaMultiplier = g("aa", ct.alphaMultiplier * 100) / 100;
			ct.redOffset = g("rb", ct.redOffset);
			ct.greenOffset = g("gb", ct.greenOffset);
			ct.blueOffset = g("bb", ct.blueOffset);
			ct.alphaOffset = g("ab", ct.alphaOffset);
			c.d.transform.colorTransform = ct;
		}

		public function getColorTransform(c:AClip):AObject
		{
			var o:AObject = vm.newObject();
			if (!c) return o;
			var ct:ColorTransform = c.d.transform.colorTransform;
			vm.objSet(o, "ra", ct.redMultiplier * 100);
			vm.objSet(o, "ga", ct.greenMultiplier * 100);
			vm.objSet(o, "ba", ct.blueMultiplier * 100);
			vm.objSet(o, "aa", ct.alphaMultiplier * 100);
			vm.objSet(o, "rb", ct.redOffset);
			vm.objSet(o, "gb", ct.greenOffset);
			vm.objSet(o, "bb", ct.blueOffset);
			vm.objSet(o, "ab", ct.alphaOffset);
			return o;
		}

		private var mp3Logged:Boolean = false;

		public function newSound(id:int):Object
		{
			if (data.kinds[id] != "sound") return null;
			var m:ByteArray = data.mp3[id] as ByteArray;
			if (m && m.length)
			{
				// (from its MP3 data, not the SWF's symbol: see SwfConvert.keepMp3)
				try
				{
					var fresh:Sound = new Sound();
					// (in pieces: AIR refuses one call of more than 40 KB, Error #2084)
					m.position = 0;
					while (m.bytesAvailable > 0)
						fresh.loadCompressedDataFromByteArray(m, Math.min(32768, m.bytesAvailable));
					if (fresh.length > 0)
					{
						var tr:Object = data.mp3Trim[id];
						if (tr) SoftMixer.trim(fresh, tr.skip, tr.count);
						if (!mp3Logged) { mp3Logged = true; Log.write("avm1: sounds are made from their MP3 data (not the SWF's sound symbols)"); }
						return fresh;
					}
				}
				catch (me:Error) { vm.warnOnce("sound " + id + " from its MP3 data: " + me.message); }
			}
			try
			{
				var C:Class = domain.getDefinition(AbcGen.SOUND + id) as Class;
				return new C();
			}
			catch (e:Error)
			{
				vm.warnOnce("can't create sound " + id + ": " + e.message);
			}
			return null;
		}
	}
}
