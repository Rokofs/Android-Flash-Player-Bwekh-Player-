package fp.ui
{
	import flash.display.Shape;
	import flash.display.Sprite;
	import flash.events.Event;
	import flash.events.MouseEvent;

	/** Material switch. Dispatches Event.CHANGE when toggled by the user. */
	public class Switch extends Sprite
	{
		private var _on:Boolean;
		private var _track:Shape;
		private var _thumb:Shape;

		public function Switch(on:Boolean)
		{
			_on = on;
			graphics.beginFill(0, 0);
			graphics.drawRect(-M.px(8), -M.px(12), M.px(52), M.px(48));
			graphics.endFill();
			_track = new Shape();
			_thumb = new Shape();
			addChild(_track);
			addChild(_thumb);
			mouseChildren = false;
			buttonMode = true;
			addEventListener(MouseEvent.CLICK, onClick);
			draw();
		}

		public function get on():Boolean { return _on; }
		public function set on(v:Boolean):void { _on = v; draw(); }

		/** Toggle as if tapped (used when the whole row is tapped). */
		public function toggle():void
		{
			_on = !_on;
			draw();
			dispatchEvent(new Event(Event.CHANGE));
		}

		private function onClick(e:MouseEvent):void
		{
			e.stopPropagation();
			toggle();
		}

		private function draw():void
		{
			var w:Number = M.px(36), h:Number = M.px(14), r:Number = M.px(10);
			_track.graphics.clear();
			_track.graphics.beginFill(_on ? M.ACCENT : 0x9E9E9E, _on ? 0.5 : 0.6);
			_track.graphics.drawRoundRect(0, M.px(5), w, h, h, h);
			_track.graphics.endFill();
			_thumb.graphics.clear();
			_thumb.graphics.beginFill(_on ? M.ACCENT : 0xFAFAFA);
			_thumb.graphics.drawCircle(_on ? w - r + M.px(2) : r - M.px(2), M.px(12), r);
			_thumb.graphics.endFill();
			M.elevate(_thumb, 1);
		}
	}
}
