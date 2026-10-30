package bwekh
{
	import flash.display.Sprite;
	import flash.events.TextEvent;

	/**
	 * Test base class for a game's main class (src/fp/SoPatch.as): only tells the player that the
	 * constructor started, nothing else. Shows whether a changed base class alone stops AIR.
	 */
	public class SpritePlain extends Sprite
	{
		public function SpritePlain()
		{
			super();
			try { if (loaderInfo) loaderInfo.sharedEvents.dispatchEvent(new TextEvent("bwekh", false, false, "main class (plain base): constructor starts")); } catch (e:Error) {}
		}
	}
}
