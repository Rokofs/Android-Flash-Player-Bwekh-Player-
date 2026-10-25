package fp.ui
{
	import fp.Keys;
	import fp.Settings;

	/** "Settings" tab. Actions that need dialogs or the system are delegated to callbacks. */
	public class SettingsScreen extends ListScreen
	{
		private var s:Settings;

		public var currentPath:Function;     // ():String
		public var onPickFolder:Function;    // ():void
		public var onLayout:Function;        // ():void
		public var onQuality:Function;       // ():void
		public var onResolution:Function;    // ():void
		public var onEngine:Function;        // (as3:Boolean):void — default engine
		public var onChanged:Function;       // ():void
		public var onDownloads:Function;     // ():void — "Downloads" option changed

		public function SettingsScreen(settings:Settings)
		{
			s = settings;
		}

		public static function resolutionName(r:int):String
		{
			return r > 0 ? r + "p" : "Full size — screen resolution";
		}

		public static function qualityName(q:String):String
		{
			switch (q)
			{
				case "low": return "Low — fastest";
				case "medium": return "Medium";
				case "best": return "Best — slowest";
			}
			return "High";
		}

		override protected function build():void
		{
			header("SWF list");
			nav("SWF list path", "current: " + (currentPath != null ? currentPath() : ""), function():void { onPickFolder(); });
			toggle("Show files from Downloads", "Also list .swf files in the Download folder", s.indexDownloads, function(v:Boolean):void {
				s.indexDownloads = v;
				if (onDownloads != null) onDownloads(); else onChanged();
			});

			divider();
			header("Engines");
			nav("ActionScript 1/2 (old games)", Settings.engineInfo(s.engineFor("")), function():void { if (onEngine != null) onEngine(false); });
			nav("ActionScript 3", Settings.engineInfo(s.engineFor("", true), true), function():void { if (onEngine != null) onEngine(true); });
			note("AVM1 and Ruffle are built in and work on any phone. " +
				"If a game doesn't work, long-press it in the list and pick another engine for that file.");
			toggle("Compile AS1/AS2 code", "AVM1: translate the game's code to AIR bytecode — much faster. Turn off if a game behaves differently", s.avm1Compile, function(v:Boolean):void {
				s.avm1Compile = v;
				onChanged();
			});

			divider();
			header("Gamepad");
			toggle("On-screen gamepad", "Arrows and extra keys over the game", s.gamepadEnabled, function(v:Boolean):void {
				s.gamepadEnabled = v;
				onChanged();
			});
			nav("Gamepad layout", gamepadSummary(), function():void { onLayout(); });
			toggle("Keys from the game", "Old (AS1/AS2) games: the gamepad offers the keys the game uses", s.padAuto, function(v:Boolean):void {
				s.padAuto = v;
				onChanged();
			});
			slider("Gamepad opacity", 0.1, 1, s.gamepadOpacity, 0.05, percent, function(v:Number):void {
				s.gamepadOpacity = v;
				onChanged();
			});
			slider("Gamepad size", 0.6, 1.6, s.gamepadScale, 0.05, percent, function(v:Number):void {
				s.gamepadScale = v;
				onChanged();
			});

			divider();
			header("Render");
			nav("Render resolution", resolutionName(s.renderRes), function():void { onResolution(); });
			nav("Render quality", qualityName(s.quality), function():void { onQuality(); });
			note("Resolution: the game is drawn at this height and stretched to the screen. " +
				"Quality affects anti-aliasing of vector graphics. Lower either if a game runs slowly.");
		}

		private function gamepadSummary():String
		{
			var pad:String = s.dpadMode == "wasd" ? "WASD" : "Arrows";
			var keys:Array = [];
			for each (var code:int in s.buttons)
			{
				if (code != 0) keys.push(Keys.label(code));
			}
			return pad + " + " + (keys.length ? keys.join(", ") : "no buttons");
		}

		private static function percent(v:Number):String
		{
			return Math.round(v * 100) + "%";
		}
	}
}
