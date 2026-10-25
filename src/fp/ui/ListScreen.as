package fp.ui
{
	import flash.display.Shape;
	import flash.display.Sprite;
	import flash.events.Event;
	import flash.events.MouseEvent;
	import flash.text.TextField;

	/** Base for Material list screens (Settings, Gamepad layout). Subclasses implement build(). */
	public class ListScreen extends Sprite
	{
		protected var scroll:ScrollView;
		protected var w:Number = 100;
		protected var h:Number = 100;
		private var _y:Number = 0;

		public function ListScreen()
		{
			scroll = new ScrollView();
			addChild(scroll);
		}

		public function layout(width:Number, height:Number):void
		{
			if (width == w && height == h && scroll.content.numChildren > 0) return;
			w = width;
			h = height;
			graphics.clear();
			graphics.beginFill(M.SURFACE);
			graphics.drawRect(0, 0, w, h);
			graphics.endFill();
			scroll.setSize(w, h);
			refresh();
		}

		public function refresh():void
		{
			var keep:Number = -scroll.content.y;
			scroll.content.removeChildren();
			_y = M.px(8);
			build();
			scroll.bottomPadding = M.px(48);
			scroll.scrollTo(keep);
		}

		protected function build():void {}

		// ------------------------------------------------------------- row builders

		protected function header(text:String):void
		{
			_y += M.px(8);
			var tf:TextField = M.text(text, 14, M.ACCENT, true);
			tf.x = M.px(16);
			tf.y = _y + M.px(8);
			scroll.content.addChild(tf);
			_y += M.px(40);
		}

		protected function divider():void
		{
			var d:Shape = new Shape();
			d.graphics.beginFill(M.DIVIDER);
			d.graphics.drawRect(0, 0, w, Math.max(1, M.px(1)));
			d.graphics.endFill();
			d.y = _y;
			scroll.content.addChild(d);
			_y += M.px(1);
		}

		private function row(title:String, subtitle:String, rightSpace:Number, onTap:Function):Sprite
		{
			var r:Sprite = new Sprite();
			var tx:Number = M.px(16);
			var t:TextField = M.text("", 16, M.TEXT);
			M.fit(t, title, w - tx - rightSpace - M.px(16));
			t.x = tx;
			r.addChild(t);
			var rh:Number;
			if (subtitle)
			{
				var s:TextField = M.text(subtitle, 14, M.TEXT2, false, w - tx - rightSpace - M.px(16), true);
				s.x = tx;
				r.addChild(s);
				rh = Math.max(M.px(72), t.height + s.height + M.px(24));
				t.y = Math.round((rh - t.height - s.height) / 2);
				s.y = t.y + t.height;
			}
			else
			{
				rh = M.px(56);
				t.y = Math.round((rh - t.height) / 2);
			}
			r.graphics.beginFill(M.SURFACE, 0);
			r.graphics.drawRect(0, 0, w, rh);
			r.graphics.endFill();
			r.y = _y;
			_y += rh;
			r.cacheAsBitmap = true;
			scroll.content.addChild(r);
			if (onTap != null)
			{
				r.buttonMode = true;
				var hl:Shape = new Shape();
				r.addChildAt(hl, 0);
				r.addEventListener(MouseEvent.MOUSE_DOWN, function(e:MouseEvent):void {
					hl.graphics.clear();
					hl.graphics.beginFill(0x000000, 0.06);
					hl.graphics.drawRect(0, 0, w, rh);
					hl.graphics.endFill();
				});
				var clear:Function = function(e:MouseEvent):void { hl.graphics.clear(); };
				r.addEventListener(MouseEvent.MOUSE_UP, clear);
				r.addEventListener(MouseEvent.ROLL_OUT, clear);
				r.addEventListener(MouseEvent.CLICK, function(e:MouseEvent):void { onTap(); });
			}
			return r;
		}

		protected function nav(title:String, subtitle:String, onTap:Function):void
		{
			var r:Sprite = row(title, subtitle, M.px(40), onTap);
			var s:Number = M.px(24);
			var ch:Shape = Icons.shape("chevron", s, M.TEXT3);
			ch.x = w - s - M.px(16);
			ch.y = (r.height - s) / 2;
			r.addChild(ch);
		}

		protected function toggle(title:String, subtitle:String, on:Boolean, onChange:Function):void
		{
			var sw:Switch = new Switch(on);
			var r:Sprite = row(title, subtitle, M.px(72), function():void { sw.toggle(); });
			sw.x = w - M.px(36) - M.px(20);
			sw.y = (r.height - M.px(24)) / 2;
			sw.addEventListener(Event.CHANGE, function(e:Event):void { onChange(sw.on); });
			r.addChild(sw);
		}

		protected function slider(title:String, min:Number, max:Number, value:Number, step:Number,
		                          format:Function, onChange:Function):void
		{
			var r:Sprite = row(title, null, M.px(64), null);
			var val:TextField = M.text(format(value), 14, M.TEXT2);
			val.x = w - val.width - M.px(16);
			val.y = (M.px(56) - val.height) / 2;
			r.addChild(val);
			var sl:Slider = new Slider(w - M.px(56), min, max, value, step);
			sl.x = M.px(28);
			sl.y = _y - M.px(16);
			scroll.content.addChild(sl);
			_y = sl.y + M.px(48);
			sl.addEventListener(Event.CHANGE, function(e:Event):void {
				val.text = format(sl.value);
				val.x = w - val.width - M.px(16);
			});
			sl.addEventListener(Event.COMPLETE, function(e:Event):void { onChange(sl.value); });
		}

		protected function button(label:String, onTap:Function):void
		{
			_y += M.px(8);
			var b:TextButton = new TextButton(label);
			b.x = M.px(8);
			b.y = _y;
			b.addEventListener(MouseEvent.CLICK, function(e:MouseEvent):void { onTap(); });
			scroll.content.addChild(b);
			_y += b.h + M.px(8);
		}

		protected function note(text:String):void
		{
			var tf:TextField = M.text(text, 13, M.TEXT3, false, w - M.px(32), true);
			tf.x = M.px(16);
			tf.y = _y + M.px(4);
			scroll.content.addChild(tf);
			_y += tf.height + M.px(12);
		}
	}
}
