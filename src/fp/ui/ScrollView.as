package fp.ui
{
	import flash.display.Shape;
	import flash.display.Sprite;
	import flash.events.Event;
	import flash.events.MouseEvent;
	import flash.geom.Rectangle;
	import flash.utils.getTimer;

	/**
	 * Vertical touch-scrolling container with inertia.
	 * Put children into `content`. A tap that turned into a drag doesn't produce CLICK.
	 */
	public class ScrollView extends Sprite
	{
		public var content:Sprite = new Sprite();
		/** true while the current gesture is a drag (children can check it). */
		public var dragged:Boolean = false;

		private var _w:Number = 100;
		private var _h:Number = 100;
		private var _bar:Shape = new Shape();
		private var _down:Boolean = false;
		private var _startY:Number;
		private var _startScroll:Number;
		private var _lastY:Number;
		private var _lastT:int;
		private var _vel:Number = 0;
		private var _scroll:Number = 0;
		private var _barAlpha:Number = 0;
		public var bottomPadding:Number = 0;

		public function ScrollView()
		{
			addChild(content);
			addChild(_bar);
			addEventListener(MouseEvent.MOUSE_DOWN, onDown);
			addEventListener(MouseEvent.CLICK, onClickCapture, true, 100);
			addEventListener(MouseEvent.MOUSE_WHEEL, onWheel);
		}

		public function setSize(w:Number, h:Number):void
		{
			_w = w;
			_h = h;
			graphics.clear();
			graphics.beginFill(0, 0);
			graphics.drawRect(0, 0, w, h);
			graphics.endFill();
			scrollRect = new Rectangle(0, 0, w, h);
			scrollTo(_scroll);
		}

		public function get maxScroll():Number
		{
			return Math.max(0, content.height + bottomPadding - _h);
		}

		public function scrollTo(v:Number):void
		{
			_scroll = Math.max(0, Math.min(maxScroll, v));
			content.y = -Math.round(_scroll);
			drawBar();
		}

		private function onWheel(e:MouseEvent):void
		{
			scrollTo(_scroll - e.delta * M.px(20));
			showBar();
		}

		private function onDown(e:MouseEvent):void
		{
			_down = true;
			dragged = false;
			_vel = 0;
			_startY = stage.mouseY;
			_lastY = _startY;
			_lastT = getTimer();
			_startScroll = _scroll;
			removeEventListener(Event.ENTER_FRAME, onInertia);
			stage.addEventListener(MouseEvent.MOUSE_MOVE, onMove, true);
			stage.addEventListener(MouseEvent.MOUSE_UP, onUp, true);
		}

		private function onMove(e:MouseEvent):void
		{
			if (!_down) return;
			var y:Number = stage.mouseY;
			if (!dragged && Math.abs(y - _startY) > M.px(8)) dragged = true;
			if (dragged)
			{
				scrollTo(_startScroll - (y - _startY));
				var t:int = getTimer();
				var dt:int = Math.max(1, t - _lastT);
				_vel = 0.8 * ((_lastY - y) / dt) + 0.2 * _vel;
				_lastY = y;
				_lastT = t;
				showBar();
			}
		}

		private function onUp(e:MouseEvent):void
		{
			_down = false;
			stage.removeEventListener(MouseEvent.MOUSE_MOVE, onMove, true);
			stage.removeEventListener(MouseEvent.MOUSE_UP, onUp, true);
			if (dragged && getTimer() - _lastT < 80 && Math.abs(_vel) > 0.05)
			{
				addEventListener(Event.ENTER_FRAME, onInertia);
			}
		}

		private function onClickCapture(e:MouseEvent):void
		{
			if (dragged)
			{
				e.stopImmediatePropagation();
				dragged = false;
			}
		}

		private var _lastFrame:int = 0;

		private function onInertia(e:Event):void
		{
			var t:int = getTimer();
			var dt:Number = _lastFrame > 0 ? Math.min(50, t - _lastFrame) : 16;
			_lastFrame = t;
			scrollTo(_scroll + _vel * dt);
			_vel *= Math.pow(0.995, dt);
			showBar();
			if (Math.abs(_vel) < 0.02 || _scroll <= 0 || _scroll >= maxScroll)
			{
				_lastFrame = 0;
				removeEventListener(Event.ENTER_FRAME, onInertia);
			}
		}

		private function showBar():void
		{
			_barAlpha = 1;
			drawBar();
			removeEventListener(Event.ENTER_FRAME, fadeBar);
			addEventListener(Event.ENTER_FRAME, fadeBar);
		}

		private function fadeBar(e:Event):void
		{
			if (_down) return;
			_barAlpha -= 0.04;
			if (_barAlpha <= 0)
			{
				_barAlpha = 0;
				removeEventListener(Event.ENTER_FRAME, fadeBar);
			}
			drawBar();
		}

		private function drawBar():void
		{
			_bar.graphics.clear();
			var total:Number = content.height + bottomPadding;
			if (_barAlpha <= 0 || total <= _h) return;
			var bh:Number = Math.max(M.px(32), _h * _h / total);
			var by:Number = (_h - bh) * (_scroll / Math.max(1, maxScroll));
			_bar.graphics.beginFill(0x000000, 0.3 * _barAlpha);
			_bar.graphics.drawRoundRect(_w - M.px(5), by, M.px(3), bh, M.px(3), M.px(3));
			_bar.graphics.endFill();
		}
	}
}
