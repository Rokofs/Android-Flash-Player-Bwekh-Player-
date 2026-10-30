package fp.avm1
{
	import fp.Log;
	import flash.display.Shape;
	import flash.events.Event;
	import flash.events.SampleDataEvent;
	import flash.media.Sound;
	import flash.media.SoundTransform;
	import flash.media.SoundChannel;
	import flash.utils.ByteArray;
	import flash.utils.Dictionary;

	/**
	 * Plays the sounds a game starts from code (Sound.start) through ONE output channel,
	 * mixing them here. On Android, AIR jams when a game fires dozens of short sounds in a
	 * row (one per tap): a sound starts looping forever and keeps going after the game is
	 * closed. A single channel we feed ourselves can always be stopped.
	 *
	 * Sounds are decoded once to 44.1 kHz stereo float PCM (Sound.extract) and cached.
	 */
	public class SoftMixer
	{
		/** sounds longer than this (ms) aren't decoded whole (too much memory): decoded while they play */
		public static const MAX_DECODE_MS:Number = 100000;
		// samples per callback: 4096 (93 ms) rides out slow frames better than the minimum 2048 (46 ms)
		private static const BLOCK:int = 4096;
		private static const MAX_VOICES:int = 16;

		private var pcm:Dictionary = new Dictionary();
		private var voices:Array = [];
		private var out:Sound;
		private var outCh:SoundChannel;
		private var dead:Boolean = false;
		/**
		 * called when a voice finished: fn(voice). Never from the audio callback itself: game code
		 * there (often it starts the next sound, which means decoding it) stalls the audio thread —
		 * on Android the last buffer then repeats forever and the game freezes. Delivered on the
		 * next frame instead.
		 */
		public var onComplete:Function;
		private var finishedQueue:Array = [];
		private var ticker:Shape;

		/** every mixer not disposed yet (the player silences them all when a game ends) */
		private static var live:Array = [];

		private static var nextId:int = 1;
		public var id:int = nextId++;
		private var deadCalls:int = 0;

		/** every live mixer and what it plays (for the log) */
		public static function describe():String
		{
			var out:Array = [];
			for each (var m:SoftMixer in live)
			{
				var names:Array = [];
				for each (var v:Voice in m.voices) names.push((v.name || "?") + (v.stream ? "~" : ""));
				out.push("#" + m.id + (m.outCh ? "" : " (no output)") + ": " + (names.length ? names.join(", ") : "nothing"));
			}
			return out.length ? out.join(" | ") : "none";
		}

		/** sound -> [skip, count] (44.1 kHz samples): the part of its decoded MP3 that is the sound */
		private static var trims:Dictionary = new Dictionary(true);

		public static function trim(snd:Sound, skip:int, count:int):void
		{
			if (snd && count > 0) trims[snd] = [skip, count];
		}

		public static function killAll():int
		{
			var all:Array = live.concat();
			for each (var m:SoftMixer in all) try { m.dispose(); } catch (e:Error) {}
			live = [];
			return all.length;
		}

		public function SoftMixer()
		{
			live.push(this);
			ticker = new Shape();
			ticker.addEventListener(Event.ENTER_FRAME, deliver);
		}

		private function deliver(e:Event):void
		{
			if (!finishedQueue.length) return;
			var list:Array = finishedQueue;
			finishedQueue = [];
			if (dead || onComplete == null) return;
			for each (var f:Voice in list)
			{
				if (!f.stopped) try { onComplete(f); } catch (err:Error) {}
			}
		}

		/** decoded samples of a sound, or null if it can't / shouldn't be decoded */
		public function decode(snd:Sound):ByteArray
		{
			if (!snd) return null;
			var cached:* = pcm[snd];
			if (cached !== undefined) { lastDecode = cached ? "cached" : "not mixable"; return cached as ByteArray; }
			var ba:ByteArray = null;
			try
			{
				if (snd.length > 0 && snd.length <= MAX_DECODE_MS)
				{
					ba = new ByteArray();
					var want:Number = Math.ceil(snd.length * 44.1) + 4096;
					snd.extract(ba, want, 0);
					// a short read means extract didn't really decode it: let AIR play it
					if (ba.length < snd.length * 44.1 * 8 * 0.9) { lastDecode = "short read " + ba.length; ba = null; }
					else if (!sane(ba)) ba = null;
					else
					{
						var tr:Array = trims[snd] as Array;
						if (tr)
						{
							var from:int = Math.min(ba.length, tr[0] * 8);
							var n:int = Math.min(ba.length - from, tr[1] * 8);
							if (n > 0 && (from > 0 || n < ba.length))
							{
								var cut:ByteArray = new ByteArray();
								cut.writeBytes(ba, from, n);
								cut.position = 0;
								ba = cut;
							}
						}
						lastDecode = "ok " + Math.round(ba.length / 8 / 44.1) + " ms, peak " + lastPeak.toFixed(2) + (tr ? ", trimmed" : "");
					}
				}
			}
			catch (e:Error)
			{
				lastDecode = "error " + e.message;
				ba = null;
			}
			if (snd.length > MAX_DECODE_MS) lastDecode = "too long: " + Math.round(snd.length) + " ms";
			pcm[snd] = ba;
			return ba;
		}

		/** what the last decode found (for the log) */
		public var lastDecode:String = "";
		private var lastPeak:Number = 0;

		/**
		 * Decoded samples must be numbers in a sane range: one NaN in the mix makes the output
		 * channel NaN, and on Android that silenced all of AIR's sound (the cartoon's voices too).
		 */
		private function sane(ba:ByteArray):Boolean
		{
			ba.position = 0;
			var peak:Number = 0;
			var n:int = ba.length >> 2;
			for (var i:int = 0; i < n; i++)
			{
				var v:Number = ba.readFloat();
				if (v != v || v > 8 || v < -8) { lastDecode = "bad samples at " + i; ba.position = 0; return false; }
				if (v > peak) peak = v; else if (-v > peak) peak = -v;
			}
			ba.position = 0;
			lastPeak = peak;
			return true;
		}

		/** start a voice; null if the sound can't be mixed (caller falls back to AIR) */
		public function play(snd:Sound, offsetMs:Number, loops:int, vol:Number, pan:Number):Voice
		{
			if (dead) return null;
			var data:ByteArray = decode(snd);
			var v:Voice = new Voice();
			v.snd = snd;
			if (data)
			{
				v.data = data;
				v.pos = Math.max(0, Math.min(data.length, int(offsetMs * 44.1) * 8));
			}
			else
			{
				// a long sound (music): AIR must not play it on its own — on Android a long sound
				// AIR plays can outlive the game (heard in the menu and the next game). Here it is
				// decoded block by block as it plays, and stops with the mixer.
				if (!snd || !(snd.length > MAX_DECODE_MS)) return null;
				v.stream = true;
				v.streamLen = int(snd.length * 44.1) * 8;
				v.pos = Math.max(0, Math.min(v.streamLen, int(offsetMs * 44.1) * 8));
				lastDecode = "streamed, " + Math.round(snd.length) + " ms";
			}
			v.loops = loops < 1 ? 1 : loops;
			v.setLevel(vol, pan);
			// the same sound piling up (a shot per tap): drop the oldest copies
			var same:int = 0;
			for (var i:int = voices.length - 1; i >= 0; i--)
			{
				var o:Voice = voices[i];
				if (o.snd == snd && ++same >= 4) { o.done = true; voices.splice(i, 1); }
			}
			while (voices.length >= MAX_VOICES) (voices.shift() as Voice).done = true;
			voices.push(v);
			ensureOutput();
			return v;
		}

		public function isPlaying(snd:Sound):Boolean
		{
			for each (var v:Voice in voices) if (v.snd == snd && !v.done) return true;
			return false;
		}

		public function stopSound(snd:Sound):void
		{
			for (var i:int = voices.length - 1; i >= 0; i--)
			{
				var v:Voice = voices[i];
				if (v.snd == snd) { v.stopped = true; v.done = true; voices.splice(i, 1); }
			}
		}

		/** also restarts the output: SoundMixer.stopAll() (stopAllSounds) kills our channel too */
		public function stopAll():void
		{
			for each (var v:Voice in voices) v.done = true;
			voices = [];
			if (outCh) { try { outCh.stop(); } catch (e:Error) {} outCh = null; }
		}

		public function dispose():void
		{
			dead = true;
			var li:int = live.indexOf(this);
			if (li >= 0) live.splice(li, 1);
			finishedQueue = [];
			if (ticker) { ticker.removeEventListener(Event.ENTER_FRAME, deliver); ticker = null; }
			stopAll();
			if (outCh) { try { outCh.stop(); } catch (e:Error) {} outCh = null; }
			// (its handler stays: should AIR still ask the stopped output for sound, it gets silence
			// instead of replaying the last sound it had)
			out = null;
			pcm = new Dictionary();
		}

		private function ensureOutput():void
		{
			if (outCh || dead) return;
			if (!out)
			{
				out = new Sound();
				out.addEventListener(SampleDataEvent.SAMPLE_DATA, onSample);
			}
			try { outCh = out.play(0, 0, new SoundTransform(master)); } catch (e:Error) { outCh = null; }
		}

		/** the movie's global volume (new Sound().setVolume, no target), 0..1 */
		private var master:Number = 1;

		public function setMaster(v:Number):void
		{
			master = Math.max(0, v);
			if (outCh) try { outCh.soundTransform = new SoundTransform(master); } catch (e:Error) {}
		}

		private var streamBuf:ByteArray = new ByteArray();
		private var mixL:Vector.<Number> = new Vector.<Number>(BLOCK, true);
		private var mixR:Vector.<Number> = new Vector.<Number>(BLOCK, true);

		private function onSample(e:SampleDataEvent):void
		{
			var i:int;
			if (dead)
			{
				// (closed, yet AIR still asks it for sound)
				if (deadCalls++ < 3) Log.write("avm1: mixer #" + id + " of a closed game still asked for sound");
				for (i = 0; i < BLOCK; i++) { e.data.writeFloat(0); e.data.writeFloat(0); }
				return;
			}
			for (i = 0; i < BLOCK; i++) { mixL[i] = 0; mixR[i] = 0; }
			var finished:Array = null;
			for (var k:int = voices.length - 1; k >= 0; k--)
			{
				var v:Voice = voices[k];
				var d:ByteArray = v.data;
				var len:int = v.stream ? v.streamLen : d.length - (d.length % 8);
				var empty:int = 0;
				if (v.endPos > 0 && v.endPos < len) len = v.endPos;
				var n:int = 0;
				while (n < BLOCK && !v.done)
				{
					if (v.pos >= len)
					{
						if (--v.loops > 0) v.pos = v.startPos < len ? v.startPos : 0;
						else { v.done = true; break; }
					}
					var avail:int = (len - v.pos) >> 3;
					var take:int = avail < BLOCK - n ? avail : BLOCK - n;
					if (v.stream)
					{
						if (take > 64 && v.env) take = 64;
						streamBuf.length = 0;
						var got:int = 0;
						try { got = v.snd.extract(streamBuf, take, v.pos >> 3); } catch (xe:Error) { got = 0; }
						if (got <= 0)
						{
							// the sound is shorter than it said: this is its end
							if (++empty > 1) { v.done = true; break; }
							v.pos = len;
							continue;
						}
						empty = 0;
						take = got;
						d = streamBuf;
						d.position = 0;
					}
					else d.position = v.pos;
					var gl:Number = v.gl, gr:Number = v.gr;
					if (v.env)
					{
						// envelope: level per 64 samples (1.5 ms), smooth enough for fades
						if (take > 64) take = 64;
						v.envAt(v.envT);
						gl *= v.envL;
						gr *= v.envR;
						v.envT += take;
					}
					for (i = 0; i < take; i++)
					{
						mixL[n] += d.readFloat() * gl;
						mixR[n] += d.readFloat() * gr;
						n++;
					}
					v.pos += take << 3;
				}
				if (v.done)
				{
					voices.splice(k, 1);
					if (!finished) finished = [];
					finished.push(v);
				}
			}
			var o:ByteArray = e.data;
			for (i = 0; i < BLOCK; i++)
			{
				var l:Number = mixL[i], r:Number = mixR[i];
				if (l != l) l = 0;
				if (r != r) r = 0;
				o.writeFloat(l > 1 ? 1 : (l < -1 ? -1 : l));
				o.writeFloat(r > 1 ? 1 : (r < -1 ? -1 : r));
			}
			if (finished) finishedQueue = finishedQueue.concat(finished);
		}
	}
}
