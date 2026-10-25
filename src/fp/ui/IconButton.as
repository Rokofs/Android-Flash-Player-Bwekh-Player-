package fp.ui
{
	import flash.display.Shape;
	import flash.display.Sprite;
	import flash.events.MouseEvent;

	/** Round 48dp touch target with a 24dp icon and a press highlight. */
	public class IconButton extends Sprite
	{
		private var _icon:Shape;
		private var _hl:Shape;
		private var _size:Number;
		private var _kind:String;
		private var _pressColor:uint;

		public function IconButton(kind:String, color:uint, sizeDp:Number = 48, iconDp:Number = 24, pressColor:uint = 0x000000)
		{
			_kind = kind;
			_size = M.px(sizeDp);
			_pressColor = pressColor;
			graphics.beginFill(0, 0);
			graphics.drawCircle(_size / 2, _size / 2, _size / 2);
			graphics.endFill();
			_hl = new Shape();
			addChild(_hl);
			var s:Number = M.px(iconDp);
			_icon = Icons.shape(kind, s, color);
			_icon.x = _icon.y = (_size - s) / 2;
			addChild(_icon);
			mouseChildren = false;
			buttonMode = true;
			addEventListener(MouseEvent.MOUSE_DOWN, onDown);
			addEventListener(MouseEvent.MOUSE_UP, onUp);
			addEventListener(MouseEvent.ROLL_OUT, onUp);
		}

		public function get size():Number { return _size; }

		public function setColor(color:uint):void
		{
			_icon.graphics.clear();
			Icons.draw(_icon.graphics, _kind, M.px(24), color);
		}

		private function onDown(e:MouseEvent):void
		{
			_hl.graphics.clear();
			_hl.graphics.beginFill(_pressColor, 0.14);
			_hl.graphics.drawCircle(_size / 2, _size / 2, _size / 2);
			_hl.graphics.endFill();
		}

		private function onUp(e:MouseEvent):void
		{
			_hl.graphics.clear();
		}
	}
}
