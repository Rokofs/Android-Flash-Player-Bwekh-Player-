package fp.ui
{
	import flash.display.Shape;
	import flash.display.Sprite;
	import flash.events.Event;
	import flash.events.MouseEvent;

	/**
	 * Material slider. Event.CHANGE while dragging, Event.COMPLETE on release.
	 * Listens on the stage in the capture phase so it keeps tracking outside its bounds.
	 */
	public class Slider extends Sprite
	{
		private var _w:Number;
		private var _min:Number;
		private var _max:Number;
		private var _step:Number;
		private var _value:Number;
		private var _color:uint;
		private var _trackColor:uint;
		private var _thumb:Shape;
		private var _dragging:Boolean = false;

		public function Slider(widthPx:Number, min:Number, max:Number, value:Number, step:Number = 0,
		                       color:uint = 0xFF4081, trackColor:uint = 0xF8BBD0)
		{
			_min = min;
			_max = max;
			_value = isNaN(value) ? min : value; // must be set before the first draw()
			_step = step;
			_color = color;
			_trackColor = trackColor;
			_thumb = new Shape();
			addChild(_thumb);
			mouseChildren = false;
			addEventListener(MouseEvent.MOUSE_DOWN, onDown);
			setWidth(widthPx);
			this.value = value;
		}

		public function setWidth(w:Number):void
		{
			_w = Math.max(M.px(40), w);
			draw();
		}

		public function setRange(min:Number, max:Number):void
		{
			_min = min;
			_max = Math.max(min + 0.0001, max);
			value = _value;
		}

		public function get dragging():Boolean { return _dragging; }
		public function get value():Number { return _value; }
		public function set value(v:Number):void
		{
			if (isNaN(v)) v = _min;
			v = Math.max(_min, Math.min(_max, v));
			if (_step > 0) v = _min + Math.round((v - _min) / _step) * _step;
			_value = v;
			draw();
		}

		private function onDown(e:MouseEvent):void
		{
			e.stopPropagation(); // don't let a parent ScrollView start scrolling
			_dragging = true;
			fromMouse();
			stage.addEventListener(MouseEvent.MOUSE_MOVE, onMove, true);
			stage.addEventListener(MouseEvent.MOUSE_UP, onUp, true);
		}

		private function onMove(e:MouseEvent):void
		{
			fromMouse();
		}

		private function onUp(e:MouseEvent):void
		{
			_dragging = false;
			stage.removeEventListener(MouseEvent.MOUSE_MOVE, onMove, true);
			stage.removeEventListener(MouseEvent.MOUSE_UP, onUp, true);
			draw();
			dispatchEvent(new Event(Event.COMPLETE));
		}

		private function fromMouse():void
		{
			var old:Number = _value;
			value = _min + (_max - _min) * Math.max(0, Math.min(1, mouseX / _w));
			if (old != _value) dispatchEvent(new Event(Event.CHANGE));
		}

		private function draw():void
		{
			var h:Number = M.px(48);
			var cy:Number = h / 2;
			var t:Number = (_max > _min) ? (_value - _min) / (_max - _min) : 0;
			if (isNaN(t)) t = 0;
			t = Math.max(0, Math.min(1, t));
			var th:Number = M.px(4);
			graphics.clear();
			graphics.beginFill(0, 0);
			graphics.drawRect(-M.px(12), 0, _w + M.px(24), h);
			graphics.endFill();
			graphics.beginFill(_trackColor);
			graphics.drawRoundRect(0, cy - th / 2, _w, th, th, th);
			graphics.endFill();
			graphics.beginFill(_color);
			graphics.drawRoundRect(0, cy - th / 2, Math.max(th, _w * t), th, th, th);
			graphics.endFill();
			_thumb.graphics.clear();
			if (_dragging)
			{
				_thumb.graphics.beginFill(_color, 0.2);
				_thumb.graphics.drawCircle(_w * t, cy, M.px(18));
				_thumb.graphics.endFill();
			}
			_thumb.graphics.beginFill(_color);
			_thumb.graphics.drawCircle(_w * t, cy, M.px(9));
			_thumb.graphics.endFill();
		}
	}
}
