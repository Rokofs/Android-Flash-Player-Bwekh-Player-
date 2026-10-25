package fp.ui
{
	import flash.display.Shape;
	import flash.display.Sprite;
	import flash.events.Event;
	import flash.events.MouseEvent;
	import flash.text.TextField;

	/** Bottom navigation with three destinations. Event.CHANGE when the selection changes. */
	public class BottomNav extends Sprite
	{
		private static const ITEMS:Array = [
			{ icon: "list", label: "File list" },
			{ icon: "settings", label: "Settings" },
			{ icon: "info", label: "About" }
		];

		private var _selected:int = 0;
		private var _cells:Array = [];

		public function BottomNav()
		{
			for (var i:int = 0; i < ITEMS.length; i++)
			{
				var cell:Sprite = new Sprite();
				cell.name = String(i);
				cell.mouseChildren = false;
				cell.buttonMode = true;
				var ic:Shape = new Shape();
				ic.name = "icon";
				cell.addChild(ic);
				var tf:TextField = M.text(ITEMS[i].label, 12, M.TEXT2);
				tf.name = "label";
				cell.addChild(tf);
				cell.addEventListener(MouseEvent.CLICK, onClick);
				addChild(cell);
				_cells.push(cell);
			}
			M.elevate(this, 8);
		}

		public static function get barHeight():Number
		{
			return M.px(56);
		}

		public function get selected():int { return _selected; }
		public function set selected(i:int):void
		{
			_selected = i;
			redraw();
		}

		private function onClick(e:MouseEvent):void
		{
			var i:int = int(Sprite(e.currentTarget).name);
			if (i == _selected)
			{
				dispatchEvent(new Event(Event.SELECT));
				return;
			}
			_selected = i;
			redraw();
			dispatchEvent(new Event(Event.CHANGE));
		}

		private var _w:Number = 0;

		/** bottom = height of the system navigation bar drawn over the app; the white fills it too. */
		public function layout(w:Number, bottom:Number = 0):void
		{
			_w = w;
			var h:Number = barHeight;
			graphics.clear();
			graphics.beginFill(M.SURFACE);
			graphics.drawRect(0, 0, w, h + bottom);
			graphics.endFill();
			var cw:Number = w / _cells.length;
			for (var i:int = 0; i < _cells.length; i++)
			{
				var cell:Sprite = _cells[i];
				cell.x = Math.round(i * cw);
				cell.graphics.clear();
				cell.graphics.beginFill(0, 0);
				cell.graphics.drawRect(0, 0, cw, h);
				cell.graphics.endFill();
			}
			redraw();
		}

		private function redraw():void
		{
			if (_w <= 0) return;
			var cw:Number = _w / _cells.length;
			var h:Number = barHeight;
			var s:Number = M.px(24);
			for (var i:int = 0; i < _cells.length; i++)
			{
				var cell:Sprite = _cells[i];
				var on:Boolean = i == _selected;
				var color:uint = on ? M.ACCENT : M.TEXT2;
				var ic:Shape = Shape(cell.getChildByName("icon"));
				ic.graphics.clear();
				Icons.draw(ic.graphics, ITEMS[i].icon, s, color);
				ic.x = Math.round((cw - s) / 2);
				ic.y = M.px(7);
				var tf:TextField = TextField(cell.getChildByName("label"));
				tf.textColor = color;
				tf.x = Math.round((cw - tf.width) / 2);
				tf.y = h - tf.height - M.px(5);
			}
		}
	}
}
