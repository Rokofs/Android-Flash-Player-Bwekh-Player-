package bwekh
{
	import flash.display.DisplayObject;
	import flash.events.NetStatusEvent;
	import flash.events.TimerEvent;
	import flash.geom.Point;
	import flash.utils.ByteArray;
	import flash.utils.Dictionary;
	import flash.utils.getDefinitionByName;
	import flash.utils.getTimer;
	import flash.utils.Timer;

	/**
	 * Put into a game's SWF by the player (src/fp/GameCoords.as), first, run right away: the
	 * methods the game's renamed calls go to, set on the prototypes the game's own objects use
	 * (a loaded game has its own copies of the built-in classes: the player's prototypes don't
	 * reach its objects).
	 *  - localToGlobal / globalToLocal / hitTestPoint in the game's coordinates: "global" is the
	 *    space of the Loader the player shows the game in (named bwekhGameLoader)
	 *  - NetStream.appendBytes / appendBytesAction: a whole FLV appended is played from a file
	 *    (AIR on Android fails appended H.264) and looped; other appended video gets its
	 *    onMetaData again when it runs out (the Flash Player way of looping it)
	 */
	public class Protos
	{
		private static var ready:Boolean = setUp();

		private static function space(d:DisplayObject):DisplayObject
		{
			try
			{
				for (var x:DisplayObject = d; x; x = x.parent)
					if (x.name == "bwekhGameLoader") return x;
			}
			catch (e:Error) {}
			return null;
		}

		private static var streams:Dictionary = new Dictionary(true);
		private static var watch:Timer;

		/** lines for the player's log (it reads them from here: bwekh.Protos.messages) */
		public static var messages:Array = [];
		private static function report(text:String):void
		{
			if (messages.length < 200) messages.push(text);
		}

		private static function state(ns:Object):Object
		{
			var st:Object = streams[ns];
			if (st) return st;
			st = { at: 0, n: 0, last: -1, still: getTimer() };
			streams[ns] = st;
			ns.addEventListener(NetStatusEvent.NET_STATUS, function(e:NetStatusEvent):void {
				var code:String = e.info ? String(e.info.code) : "";
				if (int(st.codes) < 30) { st.codes = int(st.codes) + 1; report("video " + code + " at " + Number(ns.time).toFixed(2) + " s, buffer " + Number(ns.bufferLength).toFixed(2)); }
				// the game's own stream paused / resumed (its togglePause can't be renamed: the
				// game's class has a method of that name): the file playing in its place follows
				if (!st.url && (code == "NetStream.Pause.Notify" || code == "NetStream.Unpause.Notify"))
				{
					var p:Boolean = code == "NetStream.Pause.Notify";
					if (p != Boolean(st.paused))
					{
						st.paused = p;
						if (st.alt)
						{
							if (p) { try { st.alt.close(); } catch (ce:Error) {} }
							else startAlt(st);
						}
					}
				}
				if (st.url && code == "NetStream.Play.Failed" && st.loopOf && !st.loopOf.paused && int(st.retries) < 5)
				{
					st.retries = int(st.retries) + 1;
					later(function():void { if (!st.loopOf.paused) startAlt(st.loopOf); }, 300);
				}
				if (st.url && code == "NetStream.Play.Stop" && st.loopOf && st.loopOf.paused) return;
				if (st.url && code == "NetStream.Play.Stop")
				{
					// the file ended: from the start again (the game loops it)
					try { ns.seek(0); if (!(st.loopOf && st.loopOf.paused)) ns.resume(); } catch (se:Error) {}
				}
			}, false, -100, true);
			if (!watch)
			{
				watch = new Timer(500);
				watch.addEventListener(TimerEvent.TIMER, check);
				watch.start();
			}
			return st;
		}

		/**
		 * Video bytes the game appends, played from a file instead: AIR on Android fails H.264
		 * appended with appendBytes ("NetStream.Play.Failed") but plays the same FLV from a file.
		 * Returns the file's URL, or null (not a whole FLV, or no file can be written).
		 */
		private static var files:Object = {};
		private static var paths:Object = {};
		private static function fileFor(b:ByteArray):String
		{
			if (!b || b.length < 13 || b[0] != 0x46 || b[1] != 0x4C || b[2] != 0x56) return null;
			var sum:uint = 0;
			for (var i:int = 0; i < b.length; i += 997) sum = (sum * 31 + b[i]) >>> 0;
			var key:String = b.length + "_" + sum.toString(16);
			if (files[key]) return files[key];
			try
			{
				var F:Object = getDefinitionByName("flash.filesystem.File");
				var FS:Class = getDefinitionByName("flash.filesystem.FileStream") as Class;
				var dir:Object = F.applicationStorageDirectory.resolvePath("bwekh-video"); // (url: app-storage:/…)
				dir.createDirectory();
				var f:Object = dir.resolvePath(key + ".flv");
				if (!f.exists || f.size != b.length)
				{
					var fs:Object = new FS();
					fs.open(f, "write");
					fs.writeBytes(b, 0, b.length);
					fs.close();
				}
				files[key] = f.url;
				paths[f.url] = f.nativePath;
				return f.url;
			}
			catch (e:Error) { report("video file: " + e.message); }
			return null;
		}

		private static function appended(ns:Object, b:ByteArray):void
		{
			if (!ns) return;
			var st:Object = state(ns);
			st.at = getTimer();
			st.bytes = b;
			if (st.n++ < 6) report("video bytes appended (" + st.n + ", " + (b ? b.length : 0) + " bytes)");
		}

		/**
		 * Appended video (no file): a stream whose picture stopped and that has nothing left to
		 * play has run out — the game gets its onMetaData (it appends the next round, as in
		 * Flash Player). Video from a file: stopped at its end — from the start again.
		 */
		private static function check(e:TimerEvent):void
		{
			var now:int = getTimer();
			for (var k:Object in streams)
			{
				var ns:Object = k;
				var st:Object = streams[k];
				var t:Number;
				try { t = Number(ns.time); } catch (te:Error) { continue; }
				if (t != st.last) { st.last = t; st.still = now; continue; }
				if (st.alt) continue; // (its file's stream is checked)
				if (st.url)
				{
					if (st.loopOf && st.loopOf.paused) continue;
					if (t > 0.5 && now - st.still > 800)
					{
						st.still = now;
						if (int(st.loops) < 3) report("video file stopped at " + t.toFixed(2) + " s: from the start");
						st.loops = int(st.loops) + 1;
						try { ns.seek(0); } catch (se:Error) {}
					}
					continue;
				}
				var buf:Number = Number(ns.bufferLength);
				if (now - st.still < 1500 || now - st.at < 1500 || buf > 0.2) continue;
				st.still = now;
				st.loops = int(st.loops) + 1;
				var cl:Object = ns.client;
				if (cl && cl != ns && ("onMetaData" in cl))
				{
					if (st.loops < 5) report("video stopped at " + t.toFixed(2) + " s (buffer " + buf.toFixed(2) + "): the game's onMetaData again (" + st.loops + ")");
					try { cl.onMetaData({}); } catch (me:Error) { report("onMetaData: " + me.message); }
				}
			}
		}

		/**
		 * The game's stream can't switch from appended bytes to a file (#2004): a stream of our own
		 * plays the file, shown in the game's Video, paused and resumed with the game's stream.
		 */
		private static function playFile(ns:Object, st:Object, url:String, size:int):Boolean
		{
			try
			{
				var NC:Class = getDefinitionByName("flash.net.NetConnection") as Class;
				var NS:Class = getDefinitionByName("flash.net.NetStream") as Class;
				var nc:Object = new NC();
				nc.connect(null);
				var alt:Object = new NS(nc);
				alt.client = { onMetaData: function(m:Object):void {}, onPlayStatus: function(m:Object):void {},
					onXMPData: function(m:Object):void {} };
				var ast:Object = state(alt);
				ast.url = url;
				ast.loopOf = st;
				st.alt = alt;
				st.altUrl = url;
				if (st.video) st.video.attachNetStream(alt);
				// started a moment later: the game may pause this stream right after making it
				// (only the one it shows then gets Android's video decoder)
				later(function():void { if (!st.paused && !st.started) startAlt(st); }, 50);
				report("video: " + size + " bytes of FLV played from a file" + (st.video ? "" : " (its Video not known yet)"));
				return true;
			}
			catch (e:Error) { report("video file play: " + e.message); st.alt = null; }
			return false;
		}

		private static function startAlt(st:Object):void
		{
			var alt:Object = st.alt;
			if (!alt) return;
			st.started = true;
			try { alt.play(st.altUrl); }
			catch (pe:Error)
			{
				report("video file play: " + pe.message + " (" + st.altUrl + "), by path");
				try { alt.play(paths[st.altUrl]); } catch (pe2:Error) { report("video file play by path: " + pe2.message); }
			}
		}

		/** (flash.utils.setTimeout isn't in the compiler's definitions: a one-shot Timer) */
		private static function later(f:Function, ms:int):void
		{
			var t:Timer = new Timer(ms, 1);
			t.addEventListener(TimerEvent.TIMER, function(e:TimerEvent):void { f(); });
			t.start();
		}

		private static function setUp():Boolean
		{
			var p:Object = DisplayObject.prototype;
			p.bwekhG2Lcoord = function(pt:Point):Point {
				var r:DisplayObject = space(this as DisplayObject);
				if (r && pt) pt = r.localToGlobal(pt);
				return this.globalToLocal(pt);
			};
			p.bwekhL2Gcoord = function(pt:Point):Point {
				var q:Point = this.localToGlobal(pt);
				var r:DisplayObject = space(this as DisplayObject);
				return r && q ? r.globalToLocal(q) : q;
			};
			p.bwekhHitTest = function(x:Number, y:Number, shapeFlag:Boolean = false):Boolean {
				var r:DisplayObject = space(this as DisplayObject);
				if (r)
				{
					var g:Point = r.localToGlobal(new Point(x, y));
					x = g.x; y = g.y;
				}
				return this.hitTestPoint(x, y, shapeFlag);
			};
			p.setPropertyIsEnumerable("bwekhG2Lcoord", false);
			p.setPropertyIsEnumerable("bwekhL2Gcoord", false);
			p.setPropertyIsEnumerable("bwekhHitTest", false);
			// (NetStream looked up by name: its compile-time definition isn't wanted here)
			var n:Object = Object(getDefinitionByName("flash.net.NetStream")).prototype;
			n.bwekhAppend = function(b:ByteArray):void {
				var st:Object = state(this);
				if (st.alt) return; // a file plays in its place (the game appends again for a loop)
				var url:String = fileFor(b);
				if (url && playFile(this, st, url, b.length)) return;
				this.appendBytes(b);
				appended(this, b);
			};
			n.bwekhAppendAction = function(action:String):void {
				var st:Object = streams[this];
				if (st && st.alt) return; // the stream's video plays from a file: nothing to reset
				this.appendBytesAction(action);
			};
			n.bwekhToggle = function():void {
				// (paused or not is remembered even before a file plays in the stream's place: the
				// game pauses its second video right after making it, before its bytes come)
				var st:Object = state(this);
				if (!st.alt) { st.paused = !st.paused; this.togglePause(); return; }
				if (st.alt)
				{
					// one H.264 stream at a time on Android (a second fails): the paused one lets go
					st.paused = !st.paused;
					if (st.paused) { try { st.alt.close(); } catch (ce:Error) {} }
					else startAlt(st);
					return;
				}
				this.togglePause();
			};
			n.setPropertyIsEnumerable("bwekhAppendAction", false);
			n.setPropertyIsEnumerable("bwekhToggle", false);
			// Video.attachNetStream: which Video shows a stream (a file played in its place is shown there)
			var v:Object = Object(getDefinitionByName("flash.media.Video")).prototype;
			v.bwekhAttachNS__ = function(ns:Object):void {
				var st:Object = ns ? state(ns) : null;
				if (st) st.video = this;
				this.attachNetStream(st && st.alt ? st.alt : ns);
			};
			v.setPropertyIsEnumerable("bwekhAttachNS__", false);
			n.setPropertyIsEnumerable("bwekhAppend", false);
			n.setPropertyIsEnumerable("bwekhAppendAction", false);
			return true;
		}
	}
}
