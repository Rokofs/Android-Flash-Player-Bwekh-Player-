package fp
{
	import flash.display.BitmapData;
	import flash.display.PNGEncoderOptions;
	import flash.display.Shape;
	import flash.events.Event;
	import flash.events.EventDispatcher;
	import flash.filesystem.File;
	import flash.filesystem.FileMode;
	import flash.filesystem.FileStream;
	import flash.geom.Rectangle;
	import flash.utils.ByteArray;

	/**
	 * The list of SWF files in the library folder, plus cached header info and thumbnails.
	 * Events: Event.CHANGE (list rescanned), LibraryEvent-like "itemUpdated" via itemUpdated callback.
	 */
	public class Library extends EventDispatcher
	{
		public static const ITEM_UPDATED:String = "itemUpdated";

		public var dir:File;
		/** more folders to list (Download), read with one level of subfolders; may be unreadable */
		public var extraDirs:Array = [];
		/** extra folders that couldn't be read at the last scan (no permission?) */
		public var extraDenied:Boolean = false;
		public var items:Array = [];
		/** last item whose info / thumbnail changed (read in ITEM_UPDATED handlers) */
		public var updatedItem:LibraryItem;

		private var meta:Object = {};
		private var metaDirty:Boolean = false;
		private var queue:Array = [];
		private var ticker:Shape = new Shape();

		public function Library()
		{
			loadMeta();
		}

		public function get thumbsDir():File
		{
			return File.applicationStorageDirectory.resolvePath("thumbs");
		}

		public function thumbFile(item:LibraryItem):File
		{
			return thumbsDir.resolvePath(item.key + ".png");
		}

		public function setDir(d:File):void
		{
			dir = d;
			try { if (!dir.exists) dir.createDirectory(); } catch (e:Error) {}
		}

		/** Re-read the folder. Returns false if it cannot be listed. */
		public function scan():Boolean
		{
			var ok:Boolean = true;
			var list:Array = [];
			var seen:Object = {};
			try
			{
				if (dir && dir.exists && dir.isDirectory) addSwfs(dir, list, seen, 0);
				else ok = false;
			}
			catch (e:Error)
			{
				ok = false;
			}
			extraDenied = false;
			for each (var x:File in extraDirs)
			{
				try
				{
					if (!x || !x.exists || !x.isDirectory) continue;
					if (dir && x.nativePath == dir.nativePath) continue;
					if (!addSwfs(x, list, seen, 1)) extraDenied = true;
				}
				catch (e2:Error)
				{
					extraDenied = true;
				}
			}
			list.sortOn("mtime", Array.NUMERIC | Array.DESCENDING);
			items = list;

			queue = [];
			var thumbs:int = 0;
			for each (var it:LibraryItem in items)
			{
				migrate(it);
				if (hasThumb(it)) thumbs++;
				else Log.write("library: no thumbnail for " + it.name);
				it.info = meta[it.key];
				// "keys" / "packed" appeared in later versions — read old entries again
				if (!it.info || (it.info.ok && it.info.scan !== 2))
				{
					it.info = null;
					queue.push(it);
				}
			}
			Log.write("library: " + items.length + " files, " + thumbs + " with thumbnails, " + queue.length + " to read");
			if (queue.length > 0) ticker.addEventListener(Event.ENTER_FRAME, processQueue);
			dispatchEvent(new Event(Event.CHANGE));
			return ok;
		}

		/**
		 * Add the .swf files of a folder (and of its subfolders, `depth` levels down).
		 * False if the folder can't be listed.
		 */
		private function addSwfs(d:File, list:Array, seen:Object, depth:int):Boolean
		{
			var files:Array;
			try { files = d.getDirectoryListing(); } catch (e:Error) { return false; }
			if (!files) return false;
			for each (var f:File in files)
			{
				try
				{
					if (f.name.charAt(0) == ".") continue;
					if (f.isDirectory)
					{
						if (depth > 0) addSwfs(f, list, seen, depth - 1);
					}
					else if (f.extension && f.extension.toLowerCase() == "swf")
					{
						// the same file can be reached twice (e.g. /sdcard/Download and
						// /storage/emulated/0/Download): one entry per name + size
						var it:LibraryItem = new LibraryItem(f);
						if (seen[it.key]) continue;
						seen[it.key] = true;
						list.push(it);
					}
				}
				catch (e2:Error)
				{
				}
			}
			return true;
		}

		/** Take over the thumbnail and header info stored under the old key. */
		private function migrate(it:LibraryItem):void
		{
			if (it.oldKey == it.key) return;
			try
			{
				var oldThumb:File = thumbsDir.resolvePath(it.oldKey + ".png");
				var newThumb:File = thumbFile(it);
				if (oldThumb.exists && !newThumb.exists) oldThumb.moveTo(newThumb, true);
			}
			catch (e:Error)
			{
				Log.error("library.migrate", e);
			}
			if (!meta[it.key] && meta[it.oldKey])
			{
				meta[it.key] = meta[it.oldKey];
				delete meta[it.oldKey];
				metaDirty = true;
			}
		}

		public function find(name:String):LibraryItem
		{
			for each (var it:LibraryItem in items) if (it.name == name) return it;
			return null;
		}

		/** Reads one header per frame so big folders don't freeze the UI. */
		private function processQueue(e:Event):void
		{
			if (queue.length == 0)
			{
				ticker.removeEventListener(Event.ENTER_FRAME, processQueue);
				if (metaDirty) saveMeta();
				return;
			}
			var it:LibraryItem = queue.shift();
			readInfo(it);
			updatedItem = it;
			dispatchEvent(new Event(ITEM_UPDATED));
		}

		public function readInfo(it:LibraryItem):Object
		{
			if (it.info) return it.info;
			var o:Object = { ok: false };
			try
			{
				var bytes:ByteArray = new ByteArray();
				var fs:FileStream = new FileStream();
				fs.open(it.file, FileMode.READ);
				fs.readBytes(bytes);
				fs.close();
				var si:SwfInfo = SwfInfo.parse(bytes);
				o = {
					ok: si.signatureOk,
					parsed: si.parsed,
					w: si.width, h: si.height,
					fps: si.frameRate, frames: si.frameCount,
					as3: si.isAS3, bg: si.bgColor, ver: si.version,
					keys: si.usesKeys, packed: si.packed, scan: 2
				};
			}
			catch (err:Error)
			{
			}
			it.info = o;
			meta[it.key] = o;
			metaDirty = true;
			return o;
		}

		public function saveThumb(it:LibraryItem, bmd:BitmapData):void
		{
			try
			{
				var d:File = thumbsDir;
				if (!d.exists) d.createDirectory();
				var png:ByteArray = bmd.encode(new Rectangle(0, 0, bmd.width, bmd.height), new PNGEncoderOptions(true));
				var fs:FileStream = new FileStream();
				fs.open(thumbFile(it), FileMode.WRITE);
				fs.writeBytes(png);
				fs.close();
				Log.write("library: thumbnail saved for " + it.name + " (" + png.length + " bytes)");
				updatedItem = it;
				dispatchEvent(new Event(ITEM_UPDATED));
			}
			catch (e:Error)
			{
				Log.error("library.saveThumb", e);
			}
		}

		public function hasThumb(it:LibraryItem):Boolean
		{
			try { return thumbFile(it).exists; } catch (e:Error) {}
			return false;
		}

		public function remove(it:LibraryItem):Boolean
		{
			try
			{
				it.file.deleteFile();
				try { if (thumbFile(it).exists) thumbFile(it).deleteFile(); } catch (e2:Error) {}
				delete meta[it.key];
				saveMeta();
				scan();
				return true;
			}
			catch (e:Error)
			{
			}
			return false;
		}

		// ---------------------------------------------------------------- meta cache

		private function get metaFile():File
		{
			return File.applicationStorageDirectory.resolvePath("meta.json");
		}

		private function loadMeta():void
		{
			try
			{
				if (!metaFile.exists) return;
				var fs:FileStream = new FileStream();
				fs.open(metaFile, FileMode.READ);
				meta = JSON.parse(fs.readUTFBytes(fs.bytesAvailable)) || {};
				fs.close();
			}
			catch (e:Error)
			{
				meta = {};
			}
		}

		public function saveMeta():void
		{
			try
			{
				var fs:FileStream = new FileStream();
				fs.open(metaFile, FileMode.WRITE);
				fs.writeUTFBytes(JSON.stringify(meta));
				fs.close();
				metaDirty = false;
			}
			catch (e:Error)
			{
			}
		}
	}
}
