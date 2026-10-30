package bwekh
{
	import flash.display.Stage;
	import flash.utils.getDefinitionByName;

	/**
	 * The player's stage, for a game's main class that uses "stage" in its constructor
	 * (src/fp/SoPatch.as points those look-ups here). A browser has the stage there already;
	 * a game the player loads gets it only when it is added. Read from the app's window
	 * (the game runs in the app's sandbox, so it may).
	 */
	public var appStage:Stage = (function():Stage
	{
		try
		{
			var held:Stage = getDefinitionByName("bwekh.StageHolder").stage as Stage;
			if (held) return held;
		}
		catch (e0:Error)
		{
		}
		try
		{
			var na:Object = getDefinitionByName("flash.desktop.NativeApplication").nativeApplication;
			var w:Object = na.activeWindow;
			if (!w && na.openedWindows && na.openedWindows.length) w = na.openedWindows[0];
			return w ? w.stage as Stage : null;
		}
		catch (e:Error)
		{
		}
		return null;
	})();
}
