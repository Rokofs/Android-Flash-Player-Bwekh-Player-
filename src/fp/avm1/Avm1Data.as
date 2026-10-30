package fp.avm1
{
	import flash.utils.ByteArray;
	import flash.utils.Dictionary;

	/** AS1/AS2 code collected from a SWF by SwfConvert (code mode). Ids: 0 = main timeline. */
	public class Avm1Data
	{
		public var version:int = 6;
		/** sprite id -> { frame (1-based) -> [ByteArray, ...] } */
		public var frameActions:Object = {};
		/** [{id, code}] in file order (#initclip) */
		public var initActions:Array = [];
		/** button id -> [{flags, key, code}] */
		public var buttonConds:Object = {};
		/** "parentId/name" -> [{flags, key, code}] (onClipEvent handlers of a placed instance) */
		public var clipActions:Object = {};
		/** edit text id -> {v: variable name, html: Boolean} */
		public var textVars:Object = {};
		/** "parentId/name" -> {v, html} (placed text fields bound to a variable) */
		public var placedTextVars:Object = {};
		/** export (linkage) name -> character id */
		public var exports:Object = {};
		/** sprite id -> its stream sound: { rate, perFrame, mp3, at: {frame: first sample}, first, last } */
		public var streams:Object = {};
		/** character id -> MP3 frames of a DefineSound (the engine makes its Sound from them) */
		public var mp3:Object = {};
		/** character id -> { skip, count } in 44.1 kHz samples: the sound within its decoded MP3 */
		public var mp3Trim:Object = {};
		/** character id -> "sprite" | "button" | "sound" */
		public var kinds:Object = {};
		/** ids of DefineFont2/3 fonts (each has a fp_f_<id> class) */
		public var fonts:Array = [];
		/** sprite id -> frame count */
		public var spriteFrames:Object = {};

		/** sprite id -> { frame -> true }: the frame's code comes before the clips it places
		 *  (Flash then runs it before their onClipEvent(load) / first frame code) */
		public var actionsFirst:Object = {};

		/**
		 * The whole (uncompressed) SWF body, and where each code block was in it. Obfuscated games
		 * jump from one block into code hidden in other tags; Flash runs the file's bytes, so a
		 * jump out of a block continues in the file.
		 */
		public var source:ByteArray;
		/** code block (ByteArray) -> offset of its first byte in source */
		public var origins:Dictionary = new Dictionary(true);
		/** every instance name the SWF gives (lower case too): a name not here can't be a child */
		public var instanceNames:Object = {};
		/** a name couldn't be noted (one Object can't hold): don't rely on instanceNames */
		public var namesUnsure:Boolean = false;

		public function noteName(n:String):void
		{
			try { instanceNames[n] = true; instanceNames[n.toLowerCase()] = true; }
			catch (e:Error) { namesUnsure = true; }
		}

		/** sprite id -> { frame -> true }: frames that place / move / remove something */
		public var displayChanges:Object = {};

		public function markDisplayChange(id:int, frame:int):void
		{
			if (!displayChanges[id]) displayChanges[id] = {};
			displayChanges[id][frame] = true;
		}

		/** no frame in (from, to] changes the display list: the timeline looks the same on all of them */
		public function sameLook(id:int, from:int, to:int):Boolean
		{
			var ch:Object = displayChanges[id];
			if (!ch) return true;
			for (var f:int = from + 1; f <= to; f++) if (ch[f]) return false;
			return true;
		}

		public function setOrigin(code:ByteArray, offset:int):void
		{
			if (code && offset >= 0) origins[code] = offset;
		}

		/** sprite id -> timeline sound record: the stream sound of a clip shown inside a button,
		 *  turned into an event sound (started / stopped with the button's look, see VmDisplay) */
		public var lookSounds:Object = {};

		/** the main timeline has a stream sound (a cartoon's voices) */
		public var rootStream:Boolean = false;

		/** sprite id -> { frame -> [{id, stop, single, loops, inMs}] } — timeline event sounds (StartSound) */
		public var frameSounds:Object = {};

		public function addFrameSound(id:int, frame:int, rec:Object):void
		{
			var t:Object = frameSounds[id];
			if (!t) frameSounds[id] = t = {};
			if (!t[frame]) t[frame] = [];
			t[frame].push(rec);
		}

		public function addFrameAction(id:int, frame:int, code:ByteArray):void
		{
			var t:Object = frameActions[id];
			if (!t) frameActions[id] = t = {};
			if (!t[frame]) t[frame] = [];
			t[frame].push(code);
		}

		/** linkage name (case-insensitive) -> id, or -1 */
		public function exportId(name:String):int
		{
			if (exports[name] !== undefined) return exports[name];
			var lc:String = name.toLowerCase();
			for (var k:String in exports)
			{
				if (k.toLowerCase() == lc) return exports[k];
			}
			return -1;
		}

		public function exportName(id:int):String
		{
			for (var k:String in exports)
			{
				if (exports[k] == id) return k;
			}
			return null;
		}
	}
}
