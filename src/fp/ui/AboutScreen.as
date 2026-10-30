package fp.ui
{
	import flash.desktop.NativeApplication;
	import flash.display.Bitmap;
	import flash.display.Shape;
	import flash.display.Sprite;
	import flash.filesystem.File;
	import flash.filesystem.FileMode;
	import flash.filesystem.FileStream;
	import flash.text.TextField;

	/** "About" tab: logo, program name, versions, author. */
	public class AboutScreen extends Sprite
	{
		public static const AUTHOR:String = "vibefoxcodding LLC";

		private var _box:Sprite;

		public function AboutScreen()
		{
			_box = new Sprite();
			addChild(_box);

			var logo:Sprite = new Sprite();
			var s:Number = M.px(96);
			logo.graphics.beginFill(M.PRIMARY);
			logo.graphics.drawRoundRect(0, 0, s, s, M.px(24), M.px(24));
			logo.graphics.endFill();
			var fallback:Shape = Icons.shape("play", s, 0xFFFFFF);
			if (fallback) logo.addChild(fallback);
			M.elevate(logo, 4);
			loadLogo(logo, s, fallback);
			_box.addChild(logo);

			var title:TextField = M.text("Bwekh Player", 24, M.TEXT, true);
			_box.addChild(title);

			var lines:Array = [
				["Version", appVersion()],
				["Adobe AIR", runtimeVersion()],
				["Ruffle", ruffleVersion()],
				["Author", AUTHOR]
			];
			var ry:Number = 0;
			var rows:Sprite = new Sprite();
			for each (var l:Array in lines)
			{
				var k:TextField = M.text(l[0], 14, M.TEXT2);
				var v:TextField = M.text(l[1], 16, M.TEXT);
				k.y = ry;
				v.y = ry + k.height;
				rows.addChild(k);
				rows.addChild(v);
				ry += k.height + v.height + M.px(14);
			}
			_box.addChild(rows);

			var w:Number = M.px(280);
			logo.x = (w - s) / 2;
			title.x = (w - title.width) / 2;
			title.y = s + M.px(16);
			rows.y = title.y + title.height + M.px(28);
			for (var i:int = 0; i < rows.numChildren; i++)
			{
				var tf:TextField = TextField(rows.getChildAt(i));
				tf.x = (w - tf.width) / 2;
			}

			var lic:TextField = M.text("Adobe AIR is © HARMAN. Ruffle (ruffle.rs) is © Ruffle contributors, MIT / Apache-2.0.", 12, M.TEXT3, false, w, true);
			M.center(lic);
			lic.y = rows.y + ry + M.px(16);
			_box.addChild(lic);
		}

		public function layout(w:Number, h:Number):void
		{
			graphics.clear();
			graphics.beginFill(M.SURFACE);
			graphics.drawRect(0, 0, w, h);
			graphics.endFill();
			_box.x = Math.round((w - M.px(280)) / 2);
			_box.y = Math.round(Math.max(M.px(24), (h - _box.height) / 2));
		}

		/** the app icon, built into the program (icons/icon512.png) */
		[Embed(source="../../../icons/icon512.png")]
		private static const LogoPng:Class;

		private static function loadLogo(logo:Sprite, s:Number, fallback:Shape):void
		{
			try
			{
				var bmp:Bitmap = new LogoPng() as Bitmap;
				if (!bmp) return;
				bmp.smoothing = true;
				bmp.width = s;
				bmp.height = s;
				var mask:Shape = new Shape();
				mask.graphics.beginFill(0);
				mask.graphics.drawRoundRect(0, 0, s, s, M.px(24), M.px(24));
				mask.graphics.endFill();
				logo.addChild(bmp);
				logo.addChild(mask);
				bmp.mask = mask;
				if (fallback && fallback.parent) fallback.parent.removeChild(fallback);
			}
			catch (err:Error)
			{
			}
		}

		private static function appVersion():String
		{
			try
			{
				var xml:XML = NativeApplication.nativeApplication.applicationDescriptor;
				var ns:Namespace = xml.namespace();
				var label:String = String(xml.ns::versionLabel);
				return label ? label : String(xml.ns::versionNumber);
			}
			catch (e:Error)
			{
			}
			return "1.9.2";
		}

		/** native Ruffle (version written by make-apk) or the web build in the WebView */
		private static function ruffleVersion():String
		{
			try
			{
				var f:File = File.applicationDirectory.resolvePath("ruffle/native.txt");
				if (f.exists)
				{
					var fs:FileStream = new FileStream();
					fs.open(f, FileMode.READ);
					var v:String = fs.readUTFBytes(fs.bytesAvailable).replace(/^\s+|\s+$/g, "");
					fs.close();
					if (v.indexOf("Ruffle:") == 0) v = "native";
					return (v || "native") + ", built in (no WebView)";
				}
				if (File.applicationDirectory.resolvePath("ruffle/ruffle.js").exists) return "0.7.1, in WebView";
			}
			catch (e:Error)
			{
			}
			return "not included";
		}

		private static function runtimeVersion():String
		{
			try
			{
				return NativeApplication.nativeApplication.runtimeVersion;
			}
			catch (e:Error)
			{
			}
			return "?";
		}
	}
}
