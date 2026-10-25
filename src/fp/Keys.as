package fp
{
	/**
	 * Keys that the on-screen gamepad can press.
	 * code = Flash keyCode, label = short caption, key/jsCode = browser KeyboardEvent.key/.code,
	 * ch = charCode Flash reports for that key.
	 */
	public class Keys
	{
		private static var _all:Array;
		private static var _byCode:Object;

		public static function get all():Array
		{
			if (!_all) build();
			return _all;
		}

		public static function byCode(code:int):Object
		{
			if (!_all) build();
			return _byCode[code];
		}

		public static function label(code:int):String
		{
			if (code == 0) return "—";
			var k:Object = byCode(code);
			return k ? k.label : String(code);
		}

		/** Long name for pickers. */
		public static function name(code:int):String
		{
			if (code == 0) return "None (hide button)";
			var k:Object = byCode(code);
			return k ? k.name : "Key " + code;
		}

		private static function add(code:int, label:String, name:String, key:String, jsCode:String, ch:int, loc:int = 0):void
		{
			var o:Object = { code: code, label: label, name: name, key: key, jsCode: jsCode, ch: ch, loc: loc };
			_all.push(o);
			_byCode[code] = o;
		}

		private static function build():void
		{
			_all = [];
			_byCode = {};
			add(32, "SPC", "Space", " ", "Space", 32);
			add(13, "ENT", "Enter", "Enter", "Enter", 13);
			add(16, "SHF", "Shift", "Shift", "ShiftLeft", 0, 1);
			add(17, "CTL", "Ctrl", "Control", "ControlLeft", 0, 1);
			add(18, "ALT", "Alt", "Alt", "AltLeft", 0, 1);
			add(27, "ESC", "Esc", "Escape", "Escape", 27);
			add(9, "TAB", "Tab", "Tab", "Tab", 9);
			add(8, "BS", "Backspace", "Backspace", "Backspace", 8);
			add(38, "↑", "Arrow Up", "ArrowUp", "ArrowUp", 0);
			add(40, "↓", "Arrow Down", "ArrowDown", "ArrowDown", 0);
			add(37, "←", "Arrow Left", "ArrowLeft", "ArrowLeft", 0);
			add(39, "→", "Arrow Right", "ArrowRight", "ArrowRight", 0);
			var letters:String = "ZXCVASDFQWERTYUIOPGHJKLBNM";
			for (var i:int = 0; i < letters.length; i++)
			{
				var L:String = letters.charAt(i);
				add(L.charCodeAt(0), L, L, L.toLowerCase(), "Key" + L, L.toLowerCase().charCodeAt(0));
			}
			for (var d:int = 0; d <= 9; d++)
			{
				add(48 + d, String(d), String(d), String(d), "Digit" + d, 48 + d);
			}
		}
	}
}
