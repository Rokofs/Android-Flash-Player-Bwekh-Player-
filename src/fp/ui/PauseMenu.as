package fp.ui
{
	import flash.display.Sprite;
	import flash.events.Event;
	import flash.events.MouseEvent;
	import flash.text.TextField;

	/**
	 * Pause dialog: continue / exit / restart and a seek bar.
	 * Events: CONTINUE, EXIT, RESTART, SEEK (read seekValue).
	 */
	public class PauseMenu extends Sprite
	{
		public static const CONTINUE:String = "pmContinue";
		public static const EXIT:String = "pmExit";
		public static const RESTART:String = "pmRestart";
		public static const SEEK:String = "pmSeek";
		public static const GAMEPAD:String = "pmGamepad";
		/** "Keyboard": the phone's keyboard, its keys go to the game */
		public static const KEYBOARD:String = "pmKeyboard";

		private var _scrim:Sprite;
		private var _card:Sprite;
		private var _title:TextField;
		private var _time:TextField;
		private var _note:TextField;
		private var _slider:Slider;
		private var _cont:TextButton;
		private var _exit:TextButton;
		private var _restart:TextButton;
		private var _pad:TextButton;
		private var _kb:TextButton;

		private var _fps:Number = 24;
		private var _frames:int = 1;
		private var _seekable:Boolean = false;
		private var _w:Number = 300;
		private var _h:Number = 300;

		public function PauseMenu()
		{
			_scrim = new Sprite();
			addChild(_scrim);
			_card = new Sprite();
			addChild(_card);

			_title = M.text("Paused", 20, M.TEXT, true);
			_card.addChild(_title);
			_time = M.text("", 14, M.TEXT2);
			_card.addChild(_time);
			_note = M.text("", 13, M.TEXT3, false, M.px(300), true);
			_card.addChild(_note);

			_slider = new Slider(M.px(300), 1, 2, 1, 1);
			_slider.addEventListener(Event.CHANGE, function(e:Event):void { updateTime(); });
			_slider.addEventListener(Event.COMPLETE, function(e:Event):void { dispatchEvent(new Event(SEEK)); });
			_card.addChild(_slider);

			_restart = new TextButton("Restart");
			_exit = new TextButton("Exit");
			_cont = new TextButton("Continue", true);
			_restart.addEventListener(MouseEvent.CLICK, function(e:MouseEvent):void { dispatchEvent(new Event(RESTART)); });
			_exit.addEventListener(MouseEvent.CLICK, function(e:MouseEvent):void { dispatchEvent(new Event(EXIT)); });
			_cont.addEventListener(MouseEvent.CLICK, function(e:MouseEvent):void { dispatchEvent(new Event(CONTINUE)); });
			_card.addChild(_restart);
			_card.addChild(_exit);
			_card.addChild(_cont);

			for each (var t:String in [MouseEvent.MOUSE_DOWN, MouseEvent.MOUSE_UP, MouseEvent.CLICK])
				addEventListener(t, function(e:Event):void { e.stopPropagation(); });
			visible = false;
		}

		/** frame is 1-based; frames = total frames of the main timeline (<= 1 means not seekable). */
		/** padState: 1 = gamepad shown (offer "hide"), 0 = hidden (offer "show"), -1 = gamepad off in settings */
		public function open(title:String, frame:int, frames:int, fps:Number, seekable:Boolean, totalSeconds:Number, padState:int = -1,
			keyboard:Boolean = false):void
		{
			if (_kb)
			{
				_card.removeChild(_kb);
				_kb = null;
			}
			if (keyboard)
			{
				_kb = new TextButton("Keyboard");
				_kb.addEventListener(MouseEvent.CLICK, function(e:MouseEvent):void { dispatchEvent(new Event(KEYBOARD)); });
				_card.addChild(_kb);
			}
			if (_pad)
			{
				_card.removeChild(_pad);
				_pad = null;
			}
			if (padState >= 0)
			{
				_pad = new TextButton(padState == 1 ? "Hide gamepad" : "Show gamepad");
				_pad.addEventListener(MouseEvent.CLICK, function(e:MouseEvent):void { dispatchEvent(new Event(GAMEPAD)); });
				_card.addChild(_pad);
			}
			_fps = fps > 0 ? fps : 24;
			_frames = Math.max(1, frames);
			_seekable = seekable && frames > 1;
			M.fit(_title, title, cardWidth - M.px(48));
			_slider.visible = _seekable;
			if (_seekable)
			{
				_slider.setRange(1, _frames);
				_slider.value = frame;
				_note.text = "";
			}
			else
			{
				_note.text = frames > 1 && !seekable
					? "Seeking isn't available for this file."
					: "This file is a single-frame game, there is nothing to seek.";
			}
			_totalSeconds = totalSeconds;
			_currentKnown = seekable;
			updateTime();
			visible = true;
			layout(_w, _h);
		}

		private var _totalSeconds:Number = 0;
		private var _currentKnown:Boolean = false;

		public function get seekFrame():int
		{
			return int(_slider.value);
		}

		private function updateTime():void
		{
			var total:String = M.formatTime(_seekable ? _frames / _fps : _totalSeconds);
			var cur:String = _currentKnown ? M.formatTime((_slider.value - 1) / _fps) : "--:--:--";
			_time.text = cur + " / " + total;
		}

		private function get cardWidth():Number
		{
			return Math.min(_w - M.px(32), M.px(440));
		}

		public function layout(w:Number, h:Number):void
		{
			_w = w;
			_h = h;
			_scrim.graphics.clear();
			_scrim.graphics.beginFill(0x000000, 0.6);
			_scrim.graphics.drawRect(0, 0, w, h);
			_scrim.graphics.endFill();

			var cw:Number = cardWidth;
			var pad:Number = M.px(24);
			_title.x = pad;
			_title.y = M.px(20);
			_time.x = pad;
			_time.y = _title.y + _title.height + M.px(4);
			var y:Number = _time.y + _time.height + M.px(4);
			if (_slider.visible)
			{
				_slider.setWidth(cw - pad * 2);
				_slider.x = pad;
				_slider.y = y;
				y += M.px(48);
				_note.visible = false;
			}
			else
			{
				_note.visible = _note.text.length > 0;
				_note.width = cw - pad * 2;
				_note.x = pad;
				_note.y = y + M.px(6);
				if (_note.visible) y = _note.y + _note.height + M.px(10);
			}
			if (_pad || _kb)
			{
				var bx:Number = M.px(8);
				var bh:Number = 0;
				for each (var b:TextButton in [_pad, _kb])
				{
					if (!b) continue;
					b.x = bx;
					b.y = y;
					bx += b.w + M.px(8);
					bh = Math.max(bh, b.h);
				}
				y += bh + M.px(4);
			}
			y += M.px(8);
			_cont.x = cw - _cont.w - M.px(12);
			_cont.y = y;
			_exit.x = _cont.x - _exit.w - M.px(8);
			_exit.y = y;
			_restart.x = M.px(8);
			_restart.y = y;
			var ch:Number = y + _cont.h + M.px(12);

			_card.graphics.clear();
			_card.graphics.beginFill(M.SURFACE);
			_card.graphics.drawRoundRect(0, 0, cw, ch, M.px(8), M.px(8));
			_card.graphics.endFill();
			M.elevate(_card, 12);
			_card.x = Math.round((w - cw) / 2);
			_card.y = Math.round((h - ch) / 2);
		}
	}
}
