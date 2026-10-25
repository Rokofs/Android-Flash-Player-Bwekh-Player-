package fp.ui
{
	import flash.display.Sprite;
	import flash.events.TimerEvent;
	import flash.text.TextField;
	import flash.utils.Timer;

	/** Short message at the bottom of the screen. */
	public class Snackbar extends Sprite
	{
		private var _tf:TextField;
		private var _timer:Timer;
		private var _w:Number = 300;
		private var _bottom:Number = 0;

		public function Snackbar()
		{
			_tf = M.text("", 14, 0xFFFFFF, false, 100, true);
			addChild(_tf);
			mouseEnabled = false;
			mouseChildren = false;
			visible = false;
			_timer = new Timer(3000, 1);
			_timer.addEventListener(TimerEvent.TIMER_COMPLETE, function(e:TimerEvent):void { visible = false; });
		}

		public function show(message:String, ms:int = 3200):void
		{
			_tf.text = message;
			visible = true;
			draw();
			_timer.reset();
			_timer.delay = ms;
			_timer.start();
		}

		/** bottom = y coordinate the bar should sit above */
		public function layout(stageW:Number, bottom:Number):void
		{
			_w = Math.min(stageW - M.px(16), M.px(560));
			_bottom = bottom;
			x = Math.round((stageW - _w) / 2);
			draw();
		}

		private function draw():void
		{
			var pad:Number = M.px(16);
			_tf.width = _w - pad * 2;
			_tf.x = pad;
			_tf.y = M.px(14);
			var h:Number = _tf.height + M.px(28);
			graphics.clear();
			graphics.beginFill(M.SNACK, 0.96);
			graphics.drawRoundRect(0, 0, _w, h, M.px(8), M.px(8));
			graphics.endFill();
			y = Math.round(_bottom - h - M.px(8));
		}
	}
}
