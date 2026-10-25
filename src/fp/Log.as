package fp
{
	import flash.filesystem.File;
	import flash.filesystem.FileMode;
	import flash.filesystem.FileStream;
	import flash.events.TimerEvent;
	import flash.utils.Timer;

	/**
	 * Debug log: Download/BwekhPlayer-log.txt (and a copy in the app's files folder).
	 * Each app start begins a new section; the file is trimmed when it gets big.
	 */
	public class Log
	{
		private static var files:Array = [];
		/** false = release build: nothing is written */
		public static const ENABLED:Boolean = false;

		private static var started:Boolean = false;

		public static function init(appFilesDir:String):void
		{
			files = [];
			for each (var p:String in ["/storage/emulated/0/Download/BwekhPlayer-log.txt",
			                           appFilesDir ? appFilesDir + "/BwekhPlayer-log.txt" : null])
			{
				if (!p) continue;
				try { files.push(new File(p)); } catch (e:Error) {}
			}
			// release build: no log. Old log files from test builds are removed.
			if (!ENABLED)
			{
				for each (var old:File in files)
				{
					try { if (old.exists) old.deleteFile(); } catch (e2:Error) {}
				}
				files = [];
				started = false;
				return;
			}
			started = true;
			write("\n===== Bwekh Player started " + new Date().toString() + " =====");
		}

		/** lines not yet in the files: writing is slow on Android storage, so it happens in batches */
		private static var pending:Array = [];
		private static var timer:Timer;

		public static function write(msg:String):void
		{
			if (!ENABLED || !started) return;
			var d:Date = new Date();
			pending.push(two(d.hours) + ":" + two(d.minutes) + ":" + two(d.seconds) + "." +
				("00" + d.milliseconds).substr(-3) + "  " + msg + "\n");
			if (!timer)
			{
				timer = new Timer(1000, 1);
				timer.addEventListener(TimerEvent.TIMER, function(e:TimerEvent):void { flush(); });
			}
			if (!timer.running) timer.start();
			if (pending.length > 500) flush();
		}

		/** write what's waiting (also called when the app goes to the background) */
		public static function flush():void
		{
			if (!pending.length) return;
			var text:String = pending.join("");
			pending = [];
			for each (var f:File in files)
			{
				try
				{
					if (f.exists && f.size > 512 * 1024) f.deleteFile();
					var fs:FileStream = new FileStream();
					fs.open(f, FileMode.APPEND);
					fs.writeUTFBytes(text);
					fs.close();
				}
				catch (e:Error)
				{
				}
			}
		}

		public static function error(where:String, err:*):void
		{
			var msg:String = String(err);
			try
			{
				if (err is Error)
				{
					msg = (err as Error).errorID + ": " + (err as Error).message;
					var st:String = (err as Error).getStackTrace();
					if (st) msg += "\n" + st;
				}
			}
			catch (e:Error) {}
			write("ERROR " + where + ": " + msg);
			flush();
		}

		private static function two(n:int):String
		{
			return n < 10 ? "0" + n : String(n);
		}
	}
}
