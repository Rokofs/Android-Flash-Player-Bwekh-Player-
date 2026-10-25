package fp
{
	import flash.events.EventDispatcher;
	import flash.events.IEventDispatcher;
	import flash.events.StatusEvent;
	import flash.utils.getDefinitionByName;

	/**
	 * Thin wrapper around the FPNative extension, looked up at run time so the app
	 * still starts (with fallbacks) when the extension isn't present, e.g. in adl.
	 * Re-dispatches StatusEvent.STATUS from the extension.
	 */
	public class NativeBridge extends EventDispatcher
	{
		private var ext:Object;

		/** the last created bridge (the app has one) */
		public static var instance:NativeBridge;

		public function NativeBridge()
		{
			instance = this;
			try
			{
				var cls:Object = getDefinitionByName("com.vibefoxcodding.fpnative.FPNative");
				var inst:Object = cls.instance;
				if (inst && inst.isSupported)
				{
					ext = inst;
					IEventDispatcher(inst).addEventListener(StatusEvent.STATUS, onStatus);
				}
			}
			catch (e:Error)
			{
				ext = null;
			}
		}

		public function get available():Boolean
		{
			return ext != null;
		}

		private function call(name:String, ...args):*
		{
			if (!ext) return null;
			try
			{
				return ext.call.apply(ext, [name].concat(args));
			}
			catch (e:Error)
			{
			}
			return null;
		}

		public function get sdkInt():int
		{
			var v:* = call("sdkInt");
			return v is Number ? int(v) : 0;
		}

		public function externalFilesDir():String
		{
			var v:* = call("getExternalFilesDir");
			return v is String ? v : "";
		}

		public function pickFile(destDir:String):Boolean
		{
			return call("pickFile", destDir) === true;
		}

		public function share(path:String, mime:String, title:String):Boolean
		{
			return call("share", path, mime, title) === true;
		}

		public function hasAllFilesAccess():Boolean
		{
			if (!ext) return true;
			return call("hasAllFilesAccess") === true;
		}

		/** System bars / cutout overlapping the app, in stage pixels: {l, t, r, b}. */
		public function insets():Object
		{
			var o:Object = { l: 0, t: 0, r: 0, b: 0 };
			var v:* = call("getInsets");
			if (v is String)
			{
				var p:Array = String(v).split(",");
				if (p.length == 4)
				{
					o.l = Math.max(0, Number(p[0]) || 0);
					o.t = Math.max(0, Number(p[1]) || 0);
					o.r = Math.max(0, Number(p[2]) || 0);
					o.b = Math.max(0, Number(p[3]) || 0);
				}
			}
			return o;
		}

		/** draw the app at `scale` of the screen size (1 = full); returns a report for the log */
		public function setRenderScale(scale:Number, fixTouch:Boolean):String
		{
			var v:* = call("setRenderScale", String(scale), fixTouch ? "1" : "0");
			return v is String ? v : "";
		}

		/** "count,x,y,viewW,viewH" of the last raw touch seen while the surface is smaller */
		public function lastTouch():String
		{
			var v:* = call("lastTouch");
			return v is String ? v : "";
		}

		/** "list": as the phone is held, never upside down; "game": landscape */
		public function setOrientation(mode:String):Boolean
		{
			return call("setOrientation", mode) === true;
		}

		/** play a SWF with Ruffle (native on Android 8+, else RuffleActivity, a WebView); status "ruffle_closed" when it's closed */
		public function playRuffle(path:String, configJson:String):Boolean
		{
			return call("playRuffle", path, configJson) === true;
		}

		/** close the Ruffle player if it's open; true if it was */
		public function closeRuffle():Boolean
		{
			return call("closeRuffle") === true;
		}

		/** a .swf opened from another app ("Open with"), already copied: its path ("" if none) */
		public function takeOpened():String
		{
			var v:* = call("takeOpened");
			return v is String ? v : "";
		}

		public function requestAllFilesAccess():Boolean
		{
			return call("requestAllFilesAccess") === true;
		}

		private function onStatus(e:StatusEvent):void
		{
			dispatchEvent(new StatusEvent(StatusEvent.STATUS, false, false, e.code, e.level));
		}
	}
}
