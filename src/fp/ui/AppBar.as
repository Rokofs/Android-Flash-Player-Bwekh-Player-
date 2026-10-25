package fp.ui
{
	import flash.display.Sprite;
	import flash.events.Event;
	import flash.events.MouseEvent;
	import flash.text.TextField;

	/** Red top app bar: optional back arrow, title, optional "+" action. */
	public class AppBar extends Sprite
	{
		public static const BACK:String = "appBarBack";
		public static const ACTION:String = "appBarAction";

		private var _title:TextField;
		private var _back:IconButton;
		private var _action:IconButton;
		private var _w:Number = 100;
		private var _top:Number = 0;

		public function AppBar()
		{
			_title = M.text("Bwekh Player", 20, M.ON_PRIMARY, true);
			addChild(_title);

			_back = new IconButton("back", M.ON_PRIMARY, 48, 24, 0xFFFFFF);
			_back.addEventListener(MouseEvent.CLICK, function(e:MouseEvent):void { dispatchEvent(new Event(BACK)); });
			addChild(_back);

			_action = new IconButton("plus", M.ON_PRIMARY, 56, 36, 0xFFFFFF);
			_action.addEventListener(MouseEvent.CLICK, function(e:MouseEvent):void { dispatchEvent(new Event(ACTION)); });
			addChild(_action);
			M.elevate(this, 4);
		}

		public static function get barHeight():Number
		{
			return M.px(56);
		}

		public function configure(title:String, showBack:Boolean, showAction:Boolean):void
		{
			_title.text = title;
			_back.visible = showBack;
			_action.visible = showAction;
			layout(_w, _top);
		}

		/** top = height of the status bar drawn over the app (edge-to-edge); the red fills it too. */
		public function layout(w:Number, top:Number = 0):void
		{
			_w = w;
			_top = top;
			var h:Number = barHeight;
			graphics.clear();
			graphics.beginFill(M.PRIMARY);
			graphics.drawRect(0, 0, w, h + top);
			graphics.endFill();
			_back.x = M.px(4);
			_back.y = top + (h - _back.size) / 2;
			_title.x = _back.visible ? M.px(72) : M.px(16);
			_title.y = Math.round(top + (h - _title.height) / 2);
			_action.x = w - _action.size - M.px(4);
			_action.y = top + (h - _action.size) / 2;
		}
	}
}
