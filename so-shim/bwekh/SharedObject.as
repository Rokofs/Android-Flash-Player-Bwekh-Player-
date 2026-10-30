package bwekh
{
	import flash.events.EventDispatcher;
	import flash.utils.ByteArray;
	import flash.utils.getDefinitionByName;

	/**
	 * Save games for AS3 files played in AIR. The player rewrites the game's references to
	 * flash.net.SharedObject into this class (src/fp/SoPatch.as), so every game keeps its own
	 * saves in  app storage / saves-as3 / <game> / <path>_<name>.amf  and the player can
	 * write them out when the game is closed or the app goes to the background.
	 *
	 * Rebuild the ABC after changing this file: tools/so-shim/README.txt.
	 */
	public class SharedObject extends EventDispatcher
	{
		public static var defaultObjectEncoding:uint = 3;
		private static var dir:Object;
		private static var dirTried:Boolean = false;
		private static var all:Object = {};

		public var data:Object = {};
		public var client:Object;
		public var objectEncoding:uint = 3;
		public var fps:Number = 0;
		private var file:Object;
		private var key:String;

		public function SharedObject()
		{
			super();
			client = this;
		}

		// AIR's file classes, looked up at run time (keeps this class loadable anywhere)
		internal static function storageDir():Object
		{
			return getDefinitionByName("flash.filesystem.File").applicationStorageDirectory;
		}

		internal static function fileStream():Object
		{
			var C:Class = getDefinitionByName("flash.filesystem.FileStream") as Class;
			return new C();
		}

		/** this game's save folder (also used by bwekh.ExternalInterface) */
		public static function folder():Object
		{
			return saveDir();
		}

		private static function saveDir():Object
		{
			if (dirTried) return dir;
			dirTried = true;
			try
			{
				var cur:Object = storageDir().resolvePath("saves-as3/current.txt");
				var fs:Object = fileStream();
				fs.open(cur, "read");
				var name:String = fs.readUTFBytes(fs.bytesAvailable);
				fs.close();
				name = name.replace(/^\s+|\s+$/g, "");
				if (name) dir = storageDir().resolvePath("saves-as3/" + name);
			}
			catch (e:Error) {}
			return dir;
		}

		private static function safe(s:String):String
		{
			return s ? s.replace(/[^A-Za-z0-9._-]+/g, "_") : "";
		}

		public static function getLocal(name:String, localPath:String = null, secure:Boolean = false):SharedObject
		{
			var k:String = (localPath || "") + "|" + name;
			var so:SharedObject = all[k];
			if (so) return so;
			so = new SharedObject();
			so.key = k;
			all[k] = so;
			var d:Object = saveDir();
			if (d)
			{
				try { so.file = d.resolvePath((localPath ? safe(localPath) + "_" : "") + safe(name) + ".amf"); } catch (e:Error) {}
			}
			if (!so.readFile()) so.readOld(name, localPath, secure);
			return so;
		}

		public static function getRemote(name:String, remotePath:String = null, persistence:Object = false, secure:Boolean = false):SharedObject
		{
			return getLocal(name, "remote:" + (remotePath || ""), secure);
		}

		public static function deleteAll(url:String):int { return 0; }

		public static function getDiskUsage(url:String):int { return 0; }

		/** the player calls this when the game closes or the app goes to the background */
		public static function flushAll():int
		{
			var n:int = 0;
			for (var k:String in all)
			{
				var so:SharedObject = all[k];
				if (so && so.writeFile()) n++;
			}
			return n;
		}

		private function readFile():Boolean
		{
			if (!file) return false;
			try
			{
				if (!file.exists) return false;
				var fs:Object = fileStream();
				fs.open(file, "read");
				var b:ByteArray = new ByteArray();
				fs.readBytes(b);
				fs.close();
				b.position = 0;
				var o:Object = b.readObject();
				if (o != null && typeof o == "object") { data = o; return true; }
			}
			catch (e:Error) {}
			return false;
		}

		/** saves made before this player version: AIR's own SharedObject */
		private function readOld(name:String, localPath:String, secure:Boolean):void
		{
			try
			{
				var real:Object = getDefinitionByName("flash.net.SharedObject");
				var old:Object = real.getLocal(name, localPath, secure);
				if (old && old.data)
				{
					var n:int = 0;
					for (var p:String in old.data) { data[p] = old.data[p]; n++; }
				}
			}
			catch (e:Error) {}
		}

		private function writeFile():Boolean
		{
			if (!file) return false;
			try
			{
				var b:ByteArray = new ByteArray();
				b.writeObject(data);
				file.parent.createDirectory();
				var tmp:Object = file.parent.resolvePath(file.name + ".tmp");
				var fs:Object = fileStream();
				fs.open(tmp, "write");
				fs.writeBytes(b);
				fs.close();
				tmp.moveTo(file, true);
				return true;
			}
			catch (e:Error) {}
			return false;
		}

		public function flush(minDiskSpace:int = 0):String
		{
			writeFile();
			return "flushed";
		}

		public function clear():void
		{
			for (var p:String in data) delete data[p];
			try { if (file && file.exists) file.deleteFile(); } catch (e:Error) {}
		}

		public function close():void {}

		public function connect(myConnection:Object, params:String = null):void {}

		public function send(...args):void {}

		public function setDirty(propertyName:String):void {}

		public function setProperty(propertyName:String, value:Object = null):void
		{
			data[propertyName] = value;
		}

		public function get size():uint
		{
			try
			{
				var b:ByteArray = new ByteArray();
				b.writeObject(data);
				return b.length;
			}
			catch (e:Error) {}
			return 0;
		}
	}
}
