package
{
	import flash.desktop.NativeApplication;
	import flash.display.Loader;
	import flash.display.Sprite;
	import flash.display.StageAlign;
	import flash.display.StageScaleMode;
	import flash.events.ErrorEvent;
	import flash.events.Event;
	import flash.events.TextEvent;
	import flash.events.UncaughtErrorEvent;
	import flash.filesystem.File;
	import flash.filesystem.FileMode;
	import flash.filesystem.FileStream;
	import flash.system.ApplicationDomain;
	import flash.system.LoaderContext;
	import flash.utils.ByteArray;
	import flash.utils.getTimer;
	import flash.utils.setTimeout;
	import fp.SoPatch;

	/**
	 * Desktop test of how AIR takes a game patched by SoPatch (tools/airtest/run.ps1).
	 * Loads game.swf as is, then with the main class on a plain base, then on the stage base,
	 * 6 s each, and writes every step to airtest-log.txt right away (if AIR stops, the last
	 * line shows where).
	 */
	public class AirTest extends Sprite
	{
		private static const NAMES:Array = ["as it is", "constructor reads bwekh.appStage (lazy code)", "constructor reads bwekh.appStage (eager code)"];
		private static const FORCE:Array = [false, false, false];
		private static const FLAGS:Array = [1, 1, 0];
		private static const FIX:Array = [0, 3, 3];
		private static const BUILTIN:Array = [false, false, false];
		private static const REUSE:Array = [0, 0, 0];
		private static const NOADD:Array = [false, false, false];

		private var dir:File;
		private var logFile:File;
		private var bytes:ByteArray;
		private var loader:Loader;
		private var variant:int = -1;
		private var t0:int;
		private var frames:int;

		public function AirTest()
		{
			stage.scaleMode = StageScaleMode.NO_SCALE;
			stage.align = StageAlign.TOP_LEFT;
			dir = new File(File.applicationDirectory.nativePath);
			logFile = dir.resolvePath("airtest-log.txt");
			try { if (logFile.exists) logFile.deleteFile(); } catch (e:Error) {}
			log("AIR " + NativeApplication.nativeApplication.runtimeVersion);
			var f:File = dir.resolvePath("game.swf");
			var fs:FileStream = new FileStream();
			fs.open(f, FileMode.READ);
			bytes = new ByteArray();
			fs.readBytes(bytes);
			fs.close();
			log("game.swf " + bytes.length + " bytes");
			addEventListener(Event.ENTER_FRAME, onFrame);
			next();
		}

		private function log(s:String):void
		{
			var line:String = (getTimer() / 1000).toFixed(3) + "  " + s + "\r\n";
			trace(line);
			try
			{
				var fs:FileStream = new FileStream();
				fs.open(logFile, FileMode.APPEND);
				fs.writeUTFBytes(line);
				fs.close();
			}
			catch (e:Error) {}
		}

		private function onFrame(e:Event):void
		{
			frames++;
			if (frames % 30 == 0) log("  (frames run: " + frames + ")");
		}

		private function next():void
		{
			if (loader)
			{
				try { loader.unloadAndStop(); } catch (e:Error) {}
				if (loader.parent) removeChild(loader);
				loader = null;
			}
			variant++;
			if (variant >= NAMES.length)
			{
				log("done");
				setTimeout(function():void { NativeApplication.nativeApplication.exit(); }, 500);
				return;
			}
			var name:String = NAMES[variant];
			log("=== " + name);
			var b:ByteArray = bytes;
			if (variant > 0)
			{
				var p:ByteArray = null;
				SoPatch.forceShims = FORCE[variant];
				SoPatch.shimFlags = FLAGS[variant];
				SoPatch.testBuiltinBase = BUILTIN[variant];
				SoPatch.testReuseMn = REUSE[variant];
				SoPatch.testNoAdd = NOADD[variant];
				try { p = SoPatch.patch(bytes, FIX[variant]); } catch (pe:Error) { log("patch error " + pe); }
				log("patched: " + (p ? p.length + " bytes" : "null"));
				if (!p) { setTimeout(next, 100); return; }
				b = p;
			}
			loader = new Loader();
			loader.contentLoaderInfo.addEventListener(Event.INIT, function(e:Event):void { log("INIT, content " + loader.content); });
			loader.contentLoaderInfo.addEventListener(Event.COMPLETE, function(e:Event):void { log("COMPLETE"); });
			loader.contentLoaderInfo.addEventListener(ErrorEvent.ERROR, function(e:ErrorEvent):void { log("load error " + e.text); });
			loader.contentLoaderInfo.sharedEvents.addEventListener("bwekh", function(e:TextEvent):void { log("game: " + e.text); });
			loader.uncaughtErrorEvents.addEventListener(UncaughtErrorEvent.UNCAUGHT_ERROR, function(e:UncaughtErrorEvent):void {
				e.preventDefault();
				var er:Error = e.error as Error;
				log("uncaught: " + (er ? er.errorID + " " + er.message + "\r\n" + er.getStackTrace() : e.error));
			});
			addChild(loader);
			var ctx:LoaderContext = new LoaderContext(false, new ApplicationDomain());
			ctx.allowCodeImport = true;
			log("loadBytes…");
			loader.loadBytes(b, ctx);
			log("loadBytes returned");
			var ld:Loader = loader;
			setTimeout(function():void {
				if (ld != loader) return;
				var li:* = ld.contentLoaderInfo;
				try { log("after 3 s: loaded " + li.bytesLoaded + "/" + li.bytesTotal + ", content " + ld.content); } catch (e0:Error) { log("after 3 s: " + e0); }
				var dom:ApplicationDomain = null;
				try { dom = li.applicationDomain; } catch (e1:Error) { log("domain: " + e1); }
				for each (var cn:String in ["bwekh.appStage", "com.comicViewer.interSchminter.InterSchminterViewer"])
				{
					try
					{
						var c:Object = dom ? dom.getDefinition(cn) : null;
						log("  " + cn + ": " + c);
					}
					catch (e2:Error) { log("  " + cn + ": " + e2.errorID + " " + e2.message); }
				}
				try
				{
					var C:Class = dom.getDefinition("com.comicViewer.interSchminter.InterSchminterViewer") as Class;
					log("  new main class: " + new C());
				}
				catch (e3:Error) { log("  new main class: " + e3.errorID + " " + e3.message + "\r\n" + e3.getStackTrace()); }
			}, 3000);
			setTimeout(next, 6000);
		}
	}
}
