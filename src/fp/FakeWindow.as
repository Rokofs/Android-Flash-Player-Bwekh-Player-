package fp
{
	import flash.events.Event;
	import flash.events.EventDispatcher;
	import flash.geom.Point;
	import flash.geom.Rectangle;
	import flash.utils.setTimeout;

	/**
	 * The window a desktop AIR game (a gadget, a mascot) gets for stage.nativeWindow (renamed in
	 * its code, see GameCoords). It moves, resizes and stays in front for the game alone; nothing
	 * happens to the player's real window. close() — the game's close button — goes back to the list.
	 */
	public dynamic class FakeWindow extends EventDispatcher
	{
		public var x:Number = 100;
		public var y:Number = 100;
		public var width:Number;
		public var height:Number;
		public var alwaysInFront:Boolean = false;
		public var visible:Boolean = true;
		public var active:Boolean = true;
		public var closed:Boolean = false;
		public var title:String = "";
		public var displayState:String = "normal";
		public var resizable:Boolean = false;
		public var maximizable:Boolean = false;
		public var minimizable:Boolean = true;
		public var transparent:Boolean = true;
		public var systemChrome:String = "none";
		public var type:String = "normal";
		public var minSize:Point = new Point(0, 0);
		public var maxSize:Point = new Point(4095, 4095);
		public var renderMode:String = "auto";
		private var onClose:Function;

		public function FakeWindow(w:Number, h:Number, onClose:Function)
		{
			width = w;
			height = h;
			this.onClose = onClose;
		}

		public function get bounds():Rectangle { return new Rectangle(x, y, width, height); }
		public function set bounds(r:Rectangle):void
		{
			if (!r) return;
			x = r.x; y = r.y; width = r.width; height = r.height;
		}

		public function startMove():Boolean { return true; }
		public function startResize(edge:String = "BR"):Boolean { return true; }
		public function activate():void { active = true; }
		public function minimize():void {}
		public function maximize():void {}
		public function restore():void {}
		public function orderToFront():Boolean { return true; }
		public function orderToBack():Boolean { return true; }
		public function orderInFrontOf(w:Object):Boolean { return true; }
		public function orderInBackOf(w:Object):Boolean { return true; }
		public function notifyUser(type:String):void {}
		public function globalToScreen(p:Point):Point { return new Point(p.x + x, p.y + y); }

		public function close():void
		{
			if (closed) return;
			var ev:Event = new Event(Event.CLOSING, false, true);
			dispatchEvent(ev);
			if (ev.isDefaultPrevented()) return;
			closed = true;
			dispatchEvent(new Event(Event.CLOSE));
			if (onClose != null) setTimeout(onClose, 0);
		}
	}
}
