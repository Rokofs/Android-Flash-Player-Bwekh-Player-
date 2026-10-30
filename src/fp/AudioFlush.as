package fp
{
	import flash.events.SampleDataEvent;
	import flash.events.TimerEvent;
	import flash.media.Sound;
	import flash.media.SoundChannel;
	import flash.media.SoundMixer;
	import flash.utils.Timer;

	/**
	 * Clean sound stop. On some Android devices the audio output replays its last buffer when
	 * every sound stops at once, so after stopping everything a few seconds of silence play
	 * (the output is left with silence in it). Only for a moment: a channel of silence playing
	 * all the time made the sound of games stutter on slow (32-bit) phones.
	 */
	public class AudioFlush
	{
		private static var snd:Sound;
		private static var ch:SoundChannel;
		private static var timer:Timer;
		/** (kept for the log) */
		public static var restarts:int = 0;

		/** a game was closed: stop everything, then silence for a moment */
		public static function run():void
		{
			stopAll();
		}

		/** SoundMixer.stopAll(), then silence for a moment */
		public static function stopAll():void
		{
			try { SoundMixer.stopAll(); } catch (e:Error) {}
			silence(2500);
		}

		/** something stopped all sounds: silence for a moment */
		public static function keep(force:Boolean = false):void
		{
			silence(1500);
		}

		public static function cancel():void
		{
			stopSilence();
		}

		public static function silence(ms:int):void
		{
			stopSilence();
			try
			{
				snd = new Sound();
				snd.addEventListener(SampleDataEvent.SAMPLE_DATA, onSample);
				ch = snd.play();
			}
			catch (e:Error)
			{
				ch = null;
			}
			timer = new Timer(ms, 1);
			timer.addEventListener(TimerEvent.TIMER, function(e:TimerEvent):void { stopSilence(); });
			timer.start();
		}

		private static function stopSilence():void
		{
			if (timer) { timer.stop(); timer = null; }
			if (ch) { try { ch.stop(); } catch (e:Error) {} ch = null; }
			if (snd) { snd.removeEventListener(SampleDataEvent.SAMPLE_DATA, onSample); snd = null; }
		}

		private static function onSample(e:SampleDataEvent):void
		{
			for (var i:int = 0; i < 4096; i++)
			{
				e.data.writeFloat(0);
				e.data.writeFloat(0);
			}
		}
	}
}
