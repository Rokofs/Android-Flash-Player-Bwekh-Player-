package fp
{
	import flash.events.SampleDataEvent;
	import flash.events.TimerEvent;
	import flash.media.Sound;
	import flash.media.SoundChannel;
	import flash.media.SoundMixer;
	import flash.utils.Timer;

	/**
	 * Clean sound stop after a game. On some Android devices (seen on 32-bit ARM) the audio
	 * output keeps replaying its last buffer when every sound stops at once — the game's
	 * last noise loops forever in the menu. Flash Player never let the output go idle like
	 * that, so neither do we: after stopping everything, play a couple of seconds of silence,
	 * which leaves only silence in the output buffer.
	 */
	public class AudioFlush
	{
		private static var snd:Sound;
		private static var ch:SoundChannel;
		private static var timer:Timer;

		public static function run():void
		{
			try { SoundMixer.stopAll(); } catch (e:Error) {}
			stopSilence();
			var t:Timer = new Timer(100, 1);
			t.addEventListener(TimerEvent.TIMER, function(e:TimerEvent):void {
				try { SoundMixer.stopAll(); } catch (e2:Error) {}
				startSilence(2500);
			});
			t.start();
		}

		/** a new game is starting: the silence isn't needed any more */
		public static function cancel():void
		{
			stopSilence();
		}

		private static function startSilence(ms:int):void
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
