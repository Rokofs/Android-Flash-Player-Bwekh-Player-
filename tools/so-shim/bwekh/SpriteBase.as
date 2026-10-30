package bwekh
{
	import flash.display.Sprite;
	import flash.display.Stage;
	import flash.events.Event;
	import flash.events.TextEvent;

	/**
	 * Base class put under a game's main class (src/fp/SoPatch.as). A SWF played in a browser
	 * has the stage in its main class's constructor; one loaded by the player (Loader) doesn't
	 * get it until it's added, so "stage.align = ..." in the constructor failed (#1009). Until
	 * then the stage is taken from the Loader that loads it.
	 * It also tells the player (loaderInfo.sharedEvents, "bwekh") how far it got, for the log.
	 */
	public class SpriteBase extends Sprite
	{
		private var early:int = 0;
		private var frames:int = 0;

		public function SpriteBase()
		{
			super();
			note("main class: constructor starts");
			addEventListener(Event.ADDED_TO_STAGE, onAdded);
			addEventListener(Event.ENTER_FRAME, onFrame);
		}

		private function note(s:String):void
		{
			try { if (loaderInfo) loaderInfo.sharedEvents.dispatchEvent(new TextEvent("bwekh", false, false, s)); } catch (e:Error) {}
		}

		private function onAdded(e:Event):void
		{
			removeEventListener(Event.ADDED_TO_STAGE, onAdded);
			note("main class: on the stage (" + early + " early stage look-ups)");
		}

		private function onFrame(e:Event):void
		{
			if (++frames > 3) { removeEventListener(Event.ENTER_FRAME, onFrame); return; }
			note("main class: frame " + frames + ", on stage " + (super.stage != null));
		}

		override public function get stage():Stage
		{
			var s:Stage = super.stage;
			if (s) return s;
			early++;
			if (early <= 3 || early % 1000 == 0) note("main class: stage asked before it is added (#" + early + ")");
			try
			{
				if (loaderInfo && loaderInfo.loader) return loaderInfo.loader.stage;
			}
			catch (e:Error) {}
			return null;
		}
	}
}
