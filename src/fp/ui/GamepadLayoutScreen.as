package fp.ui
{
	import fp.Keys;
	import fp.Settings;

	/** Settings → Gamepad layout. */
	public class GamepadLayoutScreen extends ListScreen
	{
		private var s:Settings;
		private var dialogs:DialogLayer;
		public var onChanged:Function;

		private static const BUTTON_NAMES:Array = ["Button A (bottom)", "Button B (right)", "Button C (left)", "Button D (top)"];

		public function GamepadLayoutScreen(settings:Settings, dialogLayer:DialogLayer)
		{
			s = settings;
			dialogs = dialogLayer;
		}

		override protected function build():void
		{
			header("Direction pad");
			nav("D-pad keys", s.dpadMode == "wasd" ? "W A S D" : "Arrow keys ↑ ← ↓ →", pickDpad);
			toggle("Swap sides", "D-pad on the right, buttons on the left", s.gamepadSwap, function(v:Boolean):void {
				s.gamepadSwap = v;
				changed();
			});

			header("Action buttons");
			for (var i:int = 0; i < 4; i++) addButtonRow(i);
			note("Common keys in Flash games: Space (jump/shoot), Z / X (action), Enter (start), Shift / Ctrl (run).");
			button("Reset to defaults", function():void {
				s.dpadMode = "arrows";
				s.gamepadSwap = false;
				s.buttons = Settings.DEFAULT_BUTTONS.concat();
				changed();
			});
		}

		private function addButtonRow(i:int):void
		{
			nav(BUTTON_NAMES[i], Keys.name(s.buttons[i]), function():void { pickKey(i); });
		}

		private function pickDpad():void
		{
			dialogs.showOptions("D-pad keys", ["Arrow keys", "W A S D"], s.dpadMode == "wasd" ? 1 : 0, function(idx:int):void {
				s.dpadMode = idx == 1 ? "wasd" : "arrows";
				changed();
			});
		}

		private function pickKey(button:int):void
		{
			var codes:Array = [0];
			var names:Array = [Keys.name(0)];
			for each (var k:Object in Keys.all)
			{
				codes.push(k.code);
				names.push(k.name);
			}
			dialogs.showOptions(BUTTON_NAMES[button], names, codes.indexOf(s.buttons[button]), function(idx:int):void {
				s.buttons[button] = codes[idx];
				changed();
			});
		}

		private function changed():void
		{
			refresh();
			if (onChanged != null) onChanged();
		}
	}
}
