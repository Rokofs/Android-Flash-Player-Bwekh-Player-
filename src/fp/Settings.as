package fp
{
	import flash.filesystem.File;
	import flash.filesystem.FileMode;
	import flash.filesystem.FileStream;

	/** Persistent settings (settings.json in the app's private storage). */
	public class Settings
	{
		/** folder with SWF files; "" = default (Android/data/<app>/files/swf) */
		public var listPath:String = "";
		/** also list the .swf files in the phone's Download folder (and its subfolders) */
		public var indexDownloads:Boolean = true;
		/** the "allow file access" question was shown once already */
		public var askedAccess:Boolean = false;

		public var gamepadEnabled:Boolean = true;
		public var gamepadOpacity:Number = 0.5;
		public var gamepadScale:Number = 1;
		public var gamepadSwap:Boolean = false;
		/** "arrows" | "wasd" */
		public var dpadMode:String = "arrows";
		/** key codes for the four action buttons (0 = hidden) */
		public var buttons:Array = [32, 90, 88, 13];
		/** let the gamepad offer the keys the game's code reads (AS1/AS2) */
		public var padAuto:Boolean = true;
		/** AVM1: translate the game's code to AS3 bytecode (faster) */
		public var avm1Compile:Boolean = true;

		/** "low" | "medium" | "high" | "best" */
		public var quality:String = "high";
		/** game render height in pixels (drawn smaller, shown scaled up); 0 = full screen size */
		public var renderRes:int = 0;
		public static const RENDER_RES:Array = [0, 1080, 720, 480, 360, 240, 144];


		public static const ENGINE_AVM1:String = "avm1";
		public static const ENGINE_RUFFLE:String = "ruffle";
		public static const ENGINE_AIR:String = "air";
		/** engines for ActionScript 1/2 files */
		public static const ENGINES:Array = [ENGINE_AVM1, ENGINE_RUFFLE];
		/** engines for ActionScript 3 files */
		public static const AS3_ENGINES:Array = [ENGINE_AIR, ENGINE_RUFFLE];

		/** engine for ActionScript 3 files unless chosen for the file: "air" | "ruffle" */
		public var as3Engine:String = ENGINE_AIR;

		/** engine for ActionScript 1/2 files unless chosen for the file: "avm1" | "ruffle"
		 *  (saved as "oldEngine": builds with Ruffle as the default saved "legacyEngine") */
		public var legacyEngine:String = ENGINE_AVM1;

		/** engine chosen for a file: name -> "ruffle" | "avm1" | "air" (absent = the default) */
		public var engineFiles:Object = {};

		public static function enginesFor(as3:Boolean):Array
		{
			return as3 ? AS3_ENGINES : ENGINES;
		}

		/** engine for a file; as3 = it's an ActionScript 3 file */
		public function engineFor(name:String, as3:Boolean = false, video:Boolean = false):String
		{
			var list:Array = enginesFor(as3);
			var e:* = engineFiles ? engineFiles[name] : null;
			if (list.indexOf(e) >= 0) return e;
			// an old file with video frames in it: AIR on Android shows that video black, Ruffle
			// decodes it (when Ruffle can't run here, the file falls back to AVM1 as usual)
			if (video && !as3) return ENGINE_RUFFLE;
			var def:String = as3 ? as3Engine : legacyEngine;
			return list.indexOf(def) >= 0 ? def : list[0];
		}

		/** saved under a new name, so the AVM1 default applies to everyone once */
		public function get oldEngine():String { return legacyEngine; }
		public function set oldEngine(v:String):void
		{
			legacyEngine = ENGINES.indexOf(v) >= 0 ? v : ENGINE_AVM1;
		}

		public static function engineName(e:String):String
		{
			if (e == ENGINE_RUFFLE) return "Ruffle";
			if (e == ENGINE_AVM1) return "AVM1";
			return "AIR";
		}

		public static function engineInfo(e:String, as3:Boolean = false):String
		{
			if (e == ENGINE_RUFFLE) return as3 ? "Ruffle — Flash emulator (ActionScript 3 support is partial)" : "Ruffle — Flash emulator";
			if (e == ENGINE_AVM1) return "AVM1 — built-in engine";
			return "AIR — Adobe AIR's own player";
		}

		/** per-file gamepad choice from the pause menu: name -> Boolean (absent = automatic) */
		public var padFiles:Object = {};


		public static const DEFAULT_BUTTONS:Array = [32, 90, 88, 13];

		private static const FIELDS:Array = [
			"listPath", "gamepadEnabled", "gamepadOpacity", "gamepadScale", "gamepadSwap",
			"dpadMode", "buttons", "padAuto", "quality", "padFiles", "engineFiles", "indexDownloads", "askedAccess", "renderRes", "oldEngine", "as3Engine", "avm1Compile"
		];

		private function get file():File
		{
			return File.applicationStorageDirectory.resolvePath("settings.json");
		}

		public function load():void
		{
			try
			{
				var f:File = file;
				if (!f.exists) return;
				var fs:FileStream = new FileStream();
				fs.open(f, FileMode.READ);
				var obj:Object = JSON.parse(fs.readUTFBytes(fs.bytesAvailable));
				fs.close();
				for each (var key:String in FIELDS)
				{
					if (obj.hasOwnProperty(key) && obj[key] != null && typeof obj[key] == typeof this[key])
						this[key] = obj[key];
				}
				if (!(buttons is Array) || buttons.length != 4) buttons = DEFAULT_BUTTONS.concat();
				if (padFiles == null || padFiles is Array) padFiles = {};
				if (engineFiles == null || engineFiles is Array) engineFiles = {};
			}
			catch (e:Error)
			{
			}
		}

		public function save():void
		{
			try
			{
				var obj:Object = {};
				for each (var key:String in FIELDS) obj[key] = this[key];
				var fs:FileStream = new FileStream();
				fs.open(file, FileMode.WRITE);
				fs.writeUTFBytes(JSON.stringify(obj, null, 2));
				fs.close();
			}
			catch (e:Error)
			{
			}
		}

		/** Should the gamepad show for this file? keysInFile = the SWF reads the keyboard (null = unknown). */
		public function padFor(name:String, keysInFile:*):Boolean
		{
			if (!gamepadEnabled) return false;
			if (padFiles && padFiles[name] is Boolean) return padFiles[name];
			return keysInFile !== false;
		}

		/**
		 * Gamepad keys for a game: the user's layout, adjusted to the keys the game reads (found, may be empty).
		 * - D-pad: arrows or WASD; switches to the other set when the game reads only that one.
		 * - Buttons: the user's buttons the game reads stay where they are; if the game reads other keys too,
		 *   they take the places of buttons it doesn't read; the other buttons stay.
		 * Returns { dpad: [up, down, left, right], buttons: [4 codes, 0 = hidden], changed: Boolean }.
		 */
		public function padLayout(found:Array):Object
		{
			var arrows:Array = [38, 40, 37, 39];
			var wasd:Array = [87, 83, 65, 68];
			var dpad:Array = dpadMode == "wasd" ? wasd : arrows;
			var btns:Array = buttons.concat();
			var res:Object = { dpad: dpad, buttons: btns, changed: false };
			if (!padAuto || !found || !found.length) return res;
			var has:Object = {};
			for each (var k:int in found) if (Keys.byCode(k)) has[k] = true;
			var n:Function = function(set:Array):int { var c:int = 0; for each (var x:int in set) if (has[x]) c++; return c; };
			if (n(dpad) == 0)
			{
				var other:Array = dpad == arrows ? wasd : arrows;
				if (n(other) > 0) { dpad = other; res.changed = true; }
			}
			var extras:Array = [];
			for each (var e:int in found)
			{
				if (!has[e] || dpad.indexOf(e) >= 0 || btns.indexOf(e) >= 0 || extras.indexOf(e) >= 0) continue;
				extras.push(e);
			}
			if (extras.length)
			{
				for (var i:int = 0; i < 4; i++)
				{
					if (!extras.length) break;
					if (btns[i] && has[btns[i]]) continue;
					btns[i] = extras.shift();
				}
				res.changed = true;
			}
			res.dpad = dpad;
			res.buttons = btns;
			return res;
		}
	}
}
