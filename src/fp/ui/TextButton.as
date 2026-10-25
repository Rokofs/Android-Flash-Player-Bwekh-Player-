package fp.ui
{
	import flash.display.Shape;
	import flash.display.Sprite;
	import flash.events.MouseEvent;
	import flash.text.TextField;

	/** Material text button ("flat") or contained button (filled with the accent colour). */
	public class TextButton extends Sprite
	{
		private var _tf:TextField;
		private var _hl:Shape;
		private var _w:Number;
		private var _h:Number;
		private var _filled:Boolean;
		private var _color:uint;

		public function TextButton(label:String, filled:Boolean = false, color:uint = 0xFF4081)
		{
			_filled = filled;
			_color = color;
			_tf = M.text(label.toUpperCase(), 14, filled ? 0xFFFFFF : color, true);
			_h = M.px(36);
			_w = Math.max(M.px(64), _tf.width + M.px(filled ? 32 : 16));
			graphics.beginFill(filled ? color : 0xFFFFFF, filled ? 1 : 0);
			graphics.drawRoundRect(0, 0, _w, _h, M.px(8), M.px(8));
			graphics.endFill();
			if (filled) M.elevate(this, 2);
			_hl = new Shape();
			addChild(_hl);
			_tf.x = Math.round((_w - _tf.width) / 2);
			_tf.y = Math.round((_h - _tf.height) / 2);
			addChild(_tf);
			mouseChildren = false;
			buttonMode = true;
			addEventListener(MouseEvent.MOUSE_DOWN, onDown);
			addEventListener(MouseEvent.MOUSE_UP, onUp);
			addEventListener(MouseEvent.ROLL_OUT, onUp);
		}

		public function get w():Number { return _w; }
		public function get h():Number { return _h; }

		private function onDown(e:MouseEvent):void
		{
			_hl.graphics.clear();
			_hl.graphics.beginFill(_filled ? 0xFFFFFF : _color, _filled ? 0.2 : 0.12);
			_hl.graphics.drawRoundRect(0, 0, _w, _h, M.px(8), M.px(8));
			_hl.graphics.endFill();
		}

		private function onUp(e:MouseEvent):void
		{
			_hl.graphics.clear();
		}
	}
}
