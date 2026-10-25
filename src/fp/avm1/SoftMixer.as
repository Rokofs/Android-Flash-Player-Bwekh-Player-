package fp.avm1
{
	import flash.display.Shape;
	import flash.events.Event;
	import flash.events.SampleDataEvent;
	import flash.media.Sound;
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
		/** sounds longer than this (ms) are played by AIR directly — too much memory to decode */
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

		public function SoftMixer()
		{
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
			if (cached !== undefined) return cached as ByteArray;
			var ba:ByteArray = null;
			try
			{
				if (snd.length > 0 && snd.length <= MAX_DECODE_MS)
				{
					ba = new ByteArray();
					var want:Number = Math.ceil(snd.length * 44.1) + 4096;
					snd.extract(ba, want, 0);
					// a short read means extract didn't really decode it: let AIR play it
					if (ba.length < snd.length * 44.1 * 8 * 0.9) ba = null;
				}
			}
			catch (e:Error)
			{
				ba = null;
			}
			pcm[snd] = ba;
			return ba;
		}

		/** start a voice; null if the sound can't be mixed (caller falls back to AIR) */
		public function play(snd:Sound, offsetMs:Number, loops:int, vol:Number, pan:Number):Voice
		{
			if (dead) return null;
			var data:ByteArray = decode(snd);
			if (!data) return null;
			var v:Voice = new Voice();
			v.snd = snd;
			v.data = data;
			v.pos = Math.max(0, Math.min(data.length, int(offsetMs * 44.1) * 8));
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
			finishedQueue = [];
			if (ticker) { ticker.removeEventListener(Event.ENTER_FRAME, deliver); ticker = null; }
			stopAll();
			if (outCh) { try { outCh.stop(); } catch (e:Error) {} outCh = null; }
			if (out) { out.removeEventListener(SampleDataEvent.SAMPLE_DATA, onSample); out = null; }
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
			try { outCh = out.play(); } catch (e:Error) { outCh = null; }
		}

		private var mixL:Vector.<Number> = new Vector.<Number>(BLOCK, true);
		private var mixR:Vector.<Number> = new Vector.<Number>(BLOCK, true);

		private function onSample(e:SampleDataEvent):void
		{
			var i:int;
			for (i = 0; i < BLOCK; i++) { mixL[i] = 0; mixR[i] = 0; }
			var finished:Array = null;
			for (var k:int = voices.length - 1; k >= 0; k--)
			{
				var v:Voice = voices[k];
				var d:ByteArray = v.data;
				var len:int = d.length - (d.length % 8);
				if (v.endPos > 0 && v.endPos < len) len = v.endPos;
				var n:int = 0;
				while (n < BLOCK && !v.done)
				{
					if (v.pos >= len)
					{
						if (--v.loops > 0) v.pos = v.startPos < len ? v.startPos : 0;
						else { v.done = true; break; }
					}
					d.position = v.pos;
					var avail:int = (len - v.pos) >> 3;
					var take:int = avail < BLOCK - n ? avail : BLOCK - n;
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
				o.writeFloat(l > 1 ? 1 : (l < -1 ? -1 : l));
				o.writeFloat(r > 1 ? 1 : (r < -1 ? -1 : r));
			}
			if (finished) finishedQueue = finishedQueue.concat(finished);
		}
	}
}
