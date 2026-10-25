package fp
{
	import flash.filesystem.File;

	public class LibraryItem
	{
		public var file:File;
		public var name:String;
		public var size:Number = 0;
		public var mtime:Number = 0;
		/** cache key (thumbnail, header info): name + size. Not the modification time: on some
		 *  phones it changes between launches, and the thumbnail was lost. */
		public var key:String;
		/** key of older versions (name + size + modification time), to pick up their thumbnails */
		public var oldKey:String;

		/** header info (null until read): {ok, w, h, fps, frames, as3, bg} */
		public var info:Object;

		/** opened with "Open with" from another app: played once, not part of the list */
		public var temporary:Boolean = false;

		public function LibraryItem(f:File)
		{
			file = f;
			name = f.name;
			try
			{
				size = f.size;
				mtime = f.modificationDate.time;
			}
			catch (e:Error)
			{
			}
			key = hash(name + "|" + size);
			oldKey = hash(name + "|" + size + "|" + mtime);
		}

		public function get baseName():String
		{
			var i:int = name.lastIndexOf(".");
			return i > 0 ? name.substr(0, i) : name;
		}

		public function get extension():String
		{
			var i:int = name.lastIndexOf(".");
			return i > 0 ? name.substr(i) : "";
		}

		public function get duration():Number
		{
			if (!info || !info.ok || !(info.fps > 0)) return 0;
			return info.frames / info.fps;
		}

		public function get isAS3():Boolean
		{
			return info && info.ok && info.as3;
		}

		private static function hash(s:String):String
		{
			// two independent 32-bit FNV-1a style hashes -> 16 hex chars
			var h1:uint = 2166136261;
			var h2:uint = 5381;
			for (var i:int = 0; i < s.length; i++)
			{
				var c:uint = s.charCodeAt(i);
				h1 = uint((h1 ^ c) * 16777619);
				h2 = uint(((h2 << 5) + h2) ^ c);
			}
			return ("00000000" + h1.toString(16)).substr(-8) + ("00000000" + h2.toString(16)).substr(-8);
		}
	}
}
