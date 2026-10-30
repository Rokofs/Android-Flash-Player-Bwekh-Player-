package fp.avm1
{
	import flash.media.Sound;
	import flash.utils.ByteArray;

	/** One sound playing in the SoftMixer (stands in for a SoundChannel). */
	public class Voice
	{
		public var snd:Sound;
		/** what it is (for the log) */
		public var name:String;
		public var data:ByteArray;
		/** a long sound decoded block by block while it plays (data is null) */
		public var stream:Boolean = false;
		/** its length in bytes (8 per stereo sample) */
		public var streamLen:int = 0;
		/** byte offset into data (8 bytes per stereo sample) */
		public var pos:int = 0;
		public var loops:int = 1;
		public var done:Boolean = false;
		/** stopped by the game (no onSoundComplete) */
		public var stopped:Boolean = false;
		public var gl:Number = 1;
		public var gr:Number = 1;
		/** game object that started it (for onSoundComplete) */
		public var owner:*;
		/** where each loop starts / ends (bytes; end 0 = the end of the sound) */
		public var startPos:int = 0;
		public var endPos:int = 0;
		/** volume envelope: flat [sample, left, right, ...] (44.1 kHz samples since start), or null */
		public var env:Array;
		/** samples played since the start (all loops) — envelope time */
		public var envT:Number = 0;
		public var envL:Number = 1;
		public var envR:Number = 1;
		private var envI:int = 0;

		/** envelope level at sample t (as Flash: linear between points, first/last level outside) */
		public function envAt(t:Number):void
		{
			var e:Array = env;
			var n:int = e.length;
			while (envI + 3 < n && t >= e[envI + 3]) envI += 3;
			var p0:Number = e[envI];
			if (t <= p0 || envI + 3 >= n)
			{
				envL = e[envI + 1];
				envR = e[envI + 2];
				return;
			}
			var p1:Number = e[envI + 3];
			var k:Number = p1 > p0 ? (t - p0) / (p1 - p0) : 1;
			envL = e[envI + 1] + (e[envI + 4] - e[envI + 1]) * k;
			envR = e[envI + 2] + (e[envI + 5] - e[envI + 2]) * k;
		}

		/** vol 0..100, pan -100..100 like AS2 */
		public function setLevel(vol:Number, pan:Number):void
		{
			var g:Number = isNaN(vol) ? 1 : Math.max(0, vol) / 100;
			var p:Number = isNaN(pan) ? 0 : Math.max(-100, Math.min(100, pan)) / 100;
			gl = g * (p > 0 ? 1 - p : 1);
			gr = g * (p < 0 ? 1 + p : 1);
		}

		/** ms played (within the current loop) */
		public function get position():Number
		{
			return pos / 8 / 44.1;
		}

		public function stop():void
		{
			stopped = true;
			done = true;
		}
	}
}
