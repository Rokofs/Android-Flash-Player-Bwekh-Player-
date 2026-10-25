package fp.ui
{
	import flash.display.DisplayObject;
	import flash.display.Graphics;
	import flash.filters.DropShadowFilter;
	import flash.system.Capabilities;
	import flash.text.AntiAliasType;
	import flash.text.TextField;
	import flash.text.TextFieldAutoSize;
	import flash.text.TextFormat;

	/** Material Design 2 theme: colours, density, text and elevation helpers. */
	public class M
	{
		// palette — red app bar, pink accent
		public static const PRIMARY:uint = 0xE53935;
		public static const PRIMARY_DARK:uint = 0xC62828;
		public static const ACCENT:uint = 0xFF4081;
		public static const ACCENT_DARK:uint = 0xF50057;
		public static const ACCENT_TINT:uint = 0xFCE4EC;
		public static const BG:uint = 0xF5F5F5;
		public static const SURFACE:uint = 0xFFFFFF;
		public static const TEXT:uint = 0x212121;
		public static const TEXT2:uint = 0x757575;
		public static const TEXT3:uint = 0x9E9E9E;
		public static const DIVIDER:uint = 0xE0E0E0;
		public static const ON_PRIMARY:uint = 0xFFFFFF;
		public static const SNACK:uint = 0x323232;

		public static const FONT:String = "_sans";

		/** pixels per density-independent pixel */
		public static var dp:Number = 1;

		public static function init():void
		{
			var dpi:Number = Capabilities.screenDPI;
			dp = Math.max(1, Math.min(4, dpi / 160));
		}

		public static function px(v:Number):Number
		{
			return Math.round(v * dp);
		}

		public static function text(s:String, sizeSp:Number, color:uint = TEXT, bold:Boolean = false,
		                            width:Number = 0, multiline:Boolean = false):TextField
		{
			var tf:TextField = new TextField();
			var fmt:TextFormat = new TextFormat(FONT, Math.round(sizeSp * dp), color, bold);
			tf.defaultTextFormat = fmt;
			tf.antiAliasType = AntiAliasType.ADVANCED;
			tf.selectable = false;
			tf.mouseEnabled = false;
			tf.tabEnabled = false;
			if (width > 0)
			{
				tf.width = width;
				tf.wordWrap = multiline;
				tf.multiline = multiline;
				tf.autoSize = TextFieldAutoSize.LEFT;
			}
			else
			{
				tf.autoSize = TextFieldAutoSize.LEFT;
			}
			tf.text = s;
			return tf;
		}

		public static function center(tf:TextField):TextField
		{
			var f:TextFormat = tf.defaultTextFormat;
			f.align = "center";
			tf.defaultTextFormat = f;
			tf.setTextFormat(f);
			return tf;
		}

		/** Cut text with an ellipsis so it fits into maxWidth. */
		public static function fit(tf:TextField, s:String, maxWidth:Number):void
		{
			tf.text = s;
			if (tf.width <= maxWidth) return;
			var lo:int = 0;
			var hi:int = s.length;
			while (lo < hi)
			{
				var mid:int = (lo + hi + 1) >> 1;
				tf.text = s.substr(0, mid) + "…";
				if (tf.width <= maxWidth) lo = mid;
				else hi = mid - 1;
			}
			tf.text = s.substr(0, lo) + "…";
		}

		public static function elevate(d:DisplayObject, level:int):void
		{
			if (level <= 0)
			{
				d.filters = [];
				return;
			}
			d.filters = [new DropShadowFilter(level * dp * 0.8, 90, 0x000000, 0.28,
				level * dp * 1.6, level * dp * 1.6, 1, 2)];
		}

		public static function roundRect(g:Graphics, x:Number, y:Number, w:Number, h:Number,
		                                 r:Number, color:uint, alpha:Number = 1):void
		{
			g.beginFill(color, alpha);
			g.drawRoundRect(x, y, w, h, r * 2, r * 2);
			g.endFill();
		}

		public static function formatTime(seconds:Number):String
		{
			if (!(seconds > 0)) seconds = 0;
			var s:int = Math.round(seconds);
			var h:int = s / 3600;
			var m:int = (s % 3600) / 60;
			var sec:int = s % 60;
			return two(h) + ":" + two(m) + ":" + two(sec);
		}

		private static function two(n:int):String
		{
			return n < 10 ? "0" + n : String(n);
		}
	}
}
