package bwekh
{
	import flash.utils.ByteArray;
	import flash.utils.getDefinitionByName;

	/**
	 * Stands in for flash.external.ExternalInterface in AS3 files played in AIR (there is no
	 * browser page). Games that keep their saves in browser cookies through JavaScript calls
	 * (snw_setCookie / getCookie / setCookie / readCookie...) get them stored in the game's
	 * save folder instead. Everything else goes to AIR's ExternalInterface as before.
	 */
	public class ExternalInterface
	{
		public static var marshallExceptions:Boolean = false;
		private static var cookies:Object;

		public static function get available():Boolean
		{
			try { return getDefinitionByName("flash.external.ExternalInterface").available; } catch (e:Error) {}
			return false;
		}

		public static function get objectID():String
		{
			try { return getDefinitionByName("flash.external.ExternalInterface").objectID; } catch (e:Error) {}
			return null;
		}

		public static function addCallback(functionName:String, closure:Function):void
		{
			try { getDefinitionByName("flash.external.ExternalInterface").addCallback(functionName, closure); } catch (e:Error) {}
		}

		public static function call(functionName:String, ...args):*
		{
			var f:String = functionName ? functionName.toLowerCase() : "";
			if (f.indexOf("cookie") >= 0 && f.length < 40 && args.length >= 1)
			{
				load();
				var key:String = String(args[0]);
				if (/(set|write|save|create|put|store)/.test(f) && args.length >= 2)
				{
					var v:* = args[1];
					var days:Number = args.length >= 3 ? Number(args[2]) : 1;
					if (v === null || v === undefined || String(v) == "" || days < 0) delete cookies[key];
					else cookies[key] = String(v);
					save();
					return null;
				}
				if (/(erase|delete|remove|clear)/.test(f))
				{
					delete cookies[key];
					save();
					return null;
				}
				if (/(get|read|load)/.test(f))
				{
					return cookies[key] !== undefined ? cookies[key] : null;
				}
			}
			var real:Object = getDefinitionByName("flash.external.ExternalInterface");
			return real.call.apply(null, [functionName].concat(args));
		}

		private static function file():Object
		{
			var d:Object = SharedObject.folder();
			return d ? d.resolvePath("cookies.amf") : null;
		}

		private static function load():void
		{
			if (cookies) return;
			cookies = {};
			try
			{
				var f:Object = file();
				if (!f || !f.exists) return;
				var fs:Object = SharedObject.fileStream();
				fs.open(f, "read");
				var b:ByteArray = new ByteArray();
				fs.readBytes(b);
				fs.close();
				b.position = 0;
				var o:Object = b.readObject();
				if (o) cookies = o;
			}
			catch (e:Error) {}
		}

		private static function save():void
		{
			try
			{
				var f:Object = file();
				if (!f) return;
				f.parent.createDirectory();
				var b:ByteArray = new ByteArray();
				b.writeObject(cookies);
				var fs:Object = SharedObject.fileStream();
				fs.open(f, "write");
				fs.writeBytes(b);
				fs.close();
			}
			catch (e:Error) {}
		}
	}
}
