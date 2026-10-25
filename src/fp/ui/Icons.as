package fp.ui
{
	import flash.display.CapsStyle;
	import flash.display.Graphics;
	import flash.display.JointStyle;
	import flash.display.LineScaleMode;
	import flash.display.Shape;

	/** Vector icons drawn in an s×s box with the origin at the top-left corner. */
	public class Icons
	{
		public static function shape(kind:String, s:Number, color:uint, alpha:Number = 1):Shape
		{
			var sh:Shape = new Shape();
			draw(sh.graphics, kind, s, color, alpha);
			return sh;
		}

		public static function draw(g:Graphics, kind:String, s:Number, color:uint, alpha:Number = 1):void
		{
			switch (kind)
			{
				case "plus":     plus(g, s, color, alpha); break;
				case "play":     play(g, s, color, alpha); break;
				case "playCircle": playCircle(g, s, color, alpha); break;
				case "share":    share(g, s, color, alpha); break;
				case "list":     list(g, s, color, alpha); break;
				case "settings": gear(g, s, color, alpha); break;
				case "info":     info(g, s, color, alpha); break;
				case "pause":    pause(g, s, color, alpha); break;
				case "back":     back(g, s, color, alpha); break;
				case "chevron":  chevron(g, s, color, alpha); break;
				case "swf":      swf(g, s, color, alpha); break;
				case "arrowUp":    arrow(g, s, color, alpha, 0); break;
				case "arrowRight": arrow(g, s, color, alpha, 90); break;
				case "arrowDown":  arrow(g, s, color, alpha, 180); break;
				case "arrowLeft":  arrow(g, s, color, alpha, 270); break;
			}
		}

		private static function stroke(g:Graphics, w:Number, color:uint, alpha:Number):void
		{
			g.lineStyle(w, color, alpha, true, LineScaleMode.NORMAL, CapsStyle.ROUND, JointStyle.ROUND);
		}

		private static function plus(g:Graphics, s:Number, c:uint, a:Number):void
		{
			var t:Number = s * 0.11;
			g.beginFill(c, a);
			g.drawRoundRect(s * 0.18, (s - t) / 2, s * 0.64, t, t, t);
			g.drawRoundRect((s - t) / 2, s * 0.18, t, s * 0.64, t, t);
			g.endFill();
		}

		private static function play(g:Graphics, s:Number, c:uint, a:Number):void
		{
			g.beginFill(c, a);
			g.moveTo(s * 0.32, s * 0.2);
			g.lineTo(s * 0.8, s * 0.5);
			g.lineTo(s * 0.32, s * 0.8);
			g.lineTo(s * 0.32, s * 0.2);
			g.endFill();
		}

		private static function playCircle(g:Graphics, s:Number, c:uint, a:Number):void
		{
			stroke(g, Math.max(1.5, s * 0.07), c, a);
			g.drawCircle(s / 2, s / 2, s * 0.44);
			g.lineStyle();
			g.beginFill(c, a);
			g.moveTo(s * 0.41, s * 0.32);
			g.lineTo(s * 0.7, s * 0.5);
			g.lineTo(s * 0.41, s * 0.68);
			g.lineTo(s * 0.41, s * 0.32);
			g.endFill();
		}

		private static function share(g:Graphics, s:Number, c:uint, a:Number):void
		{
			var r:Number = s * 0.12;
			var ax:Number = s * 0.74, ay:Number = s * 0.2;
			var bx:Number = s * 0.26, by:Number = s * 0.5;
			var cx:Number = s * 0.74, cy:Number = s * 0.8;
			stroke(g, Math.max(1.5, s * 0.07), c, a);
			g.moveTo(ax, ay); g.lineTo(bx, by); g.lineTo(cx, cy);
			g.lineStyle();
			g.beginFill(c, a);
			g.drawCircle(ax, ay, r);
			g.drawCircle(bx, by, r);
			g.drawCircle(cx, cy, r);
			g.endFill();
		}

		private static function list(g:Graphics, s:Number, c:uint, a:Number):void
		{
			g.beginFill(c, a);
			for (var i:int = 0; i < 3; i++)
			{
				var y:Number = s * (0.27 + i * 0.23);
				g.drawCircle(s * 0.2, y, s * 0.06);
				g.drawRoundRect(s * 0.33, y - s * 0.05, s * 0.52, s * 0.1, s * 0.1, s * 0.1);
			}
			g.endFill();
		}

		private static function gear(g:Graphics, s:Number, c:uint, a:Number):void
		{
			var cx:Number = s / 2, cy:Number = s / 2;
			var rOut:Number = s * 0.42, rIn:Number = s * 0.32;
			var teeth:int = 8;
			g.beginFill(c, a);
			for (var i:int = 0; i <= teeth * 4; i++)
			{
				var ang:Number = (i / (teeth * 4)) * Math.PI * 2;
				var phase:int = i % 4;
				var r:Number = (phase == 1 || phase == 2) ? rOut : rIn;
				var px:Number = cx + Math.cos(ang) * r;
				var py:Number = cy + Math.sin(ang) * r;
				if (i == 0) g.moveTo(px, py);
				else g.lineTo(px, py);
			}
			g.drawCircle(cx, cy, s * 0.13);
			g.endFill();
		}

		private static function info(g:Graphics, s:Number, c:uint, a:Number):void
		{
			g.beginFill(c, a);
			g.drawCircle(s / 2, s / 2, s * 0.42);
			g.drawCircle(s / 2, s / 2, s * 0.34);
			g.endFill();
			g.beginFill(c, a);
			g.drawCircle(s / 2, s * 0.32, s * 0.055);
			g.drawRoundRect(s * 0.455, s * 0.43, s * 0.09, s * 0.3, s * 0.06, s * 0.06);
			g.endFill();
		}

		private static function pause(g:Graphics, s:Number, c:uint, a:Number):void
		{
			g.beginFill(c, a);
			g.drawRoundRect(s * 0.27, s * 0.2, s * 0.15, s * 0.6, s * 0.06, s * 0.06);
			g.drawRoundRect(s * 0.58, s * 0.2, s * 0.15, s * 0.6, s * 0.06, s * 0.06);
			g.endFill();
		}

		private static function back(g:Graphics, s:Number, c:uint, a:Number):void
		{
			stroke(g, Math.max(2, s * 0.09), c, a);
			g.moveTo(s * 0.8, s * 0.5); g.lineTo(s * 0.22, s * 0.5);
			g.moveTo(s * 0.45, s * 0.27); g.lineTo(s * 0.22, s * 0.5); g.lineTo(s * 0.45, s * 0.73);
		}

		private static function chevron(g:Graphics, s:Number, c:uint, a:Number):void
		{
			stroke(g, Math.max(1.5, s * 0.08), c, a);
			g.moveTo(s * 0.4, s * 0.27); g.lineTo(s * 0.63, s * 0.5); g.lineTo(s * 0.4, s * 0.73);
		}

		private static function swf(g:Graphics, s:Number, c:uint, a:Number):void
		{
			// stylised "f" on a rounded square
			g.beginFill(c, a);
			g.drawRoundRect(s * 0.12, s * 0.12, s * 0.76, s * 0.76, s * 0.2, s * 0.2);
			g.endFill();
			stroke(g, s * 0.09, 0xFFFFFF, a);
			g.moveTo(s * 0.62, s * 0.3);
			g.curveTo(s * 0.48, s * 0.26, s * 0.47, s * 0.42);
			g.lineTo(s * 0.47, s * 0.72);
			g.moveTo(s * 0.36, s * 0.48); g.lineTo(s * 0.6, s * 0.48);
		}

		private static function arrow(g:Graphics, s:Number, c:uint, a:Number, rot:Number):void
		{
			var pts:Array = [[0.5, 0.25], [0.75, 0.62], [0.25, 0.62]];
			var rad:Number = rot * Math.PI / 180;
			var cos:Number = Math.cos(rad), sin:Number = Math.sin(rad);
			g.beginFill(c, a);
			for (var i:int = 0; i <= pts.length; i++)
			{
				var p:Array = pts[i % pts.length];
				var dx:Number = (p[0] - 0.5) * s, dy:Number = (p[1] - 0.5) * s;
				var x:Number = s / 2 + dx * cos - dy * sin;
				var y:Number = s / 2 + dx * sin + dy * cos;
				if (i == 0) g.moveTo(x, y);
				else g.lineTo(x, y);
			}
			g.endFill();
		}
	}
}
