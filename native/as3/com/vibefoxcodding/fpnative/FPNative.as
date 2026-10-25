package com.vibefoxcodding.fpnative
{
	import flash.events.EventDispatcher;
	import flash.events.StatusEvent;
	import flash.external.ExtensionContext;

	/**
	 * ActionScript side of the FlashPlayer native extension (Android).
	 * On other platforms the context is null and every call returns null.
	 * Status events: code = "pick" | "pick_cancel" | "pick_error" | "share_error", level = data.
	 */
	public class FPNative extends EventDispatcher
	{
		public static const EXTENSION_ID:String = "com.vibefoxcodding.fpnative";

		private static var _instance:FPNative;
		private var ctx:ExtensionContext;

		public static function get instance():FPNative
		{
			if (!_instance) _instance = new FPNative();
			return _instance;
		}

		public function FPNative()
		{
			try
			{
				ctx = ExtensionContext.createExtensionContext(EXTENSION_ID, null);
			}
			catch (e:Error)
			{
				ctx = null;
			}
			if (ctx) ctx.addEventListener(StatusEvent.STATUS, onStatus);
		}

		public function get isSupported():Boolean
		{
			return call("isSupported") === true;
		}

		public function call(name:String, ...args):*
		{
			if (!ctx) return null;
			try
			{
				return ctx.call.apply(ctx, [name].concat(args));
			}
			catch (e:Error)
			{
			}
			return null;
		}

		private function onStatus(e:StatusEvent):void
		{
			dispatchEvent(new StatusEvent(StatusEvent.STATUS, false, false, e.code, e.level));
		}
	}
}
