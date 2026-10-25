package fp.ui
{
	import flash.display.Shape;
	import flash.display.Sprite;
	import flash.events.MouseEvent;
	import flash.text.TextField;
	import flash.text.TextFieldType;
	import flash.text.TextFormat;

	/** Modal Material dialogs: option lists, confirmations and a text input. */
	public class DialogLayer extends Sprite
	{
		private var _scrim:Sprite;
		private var _card:Sprite;
		private var _w:Number = 300;
		private var _h:Number = 500;
		private var _onCancel:Function;
		private var _input:TextField;
		private var _insT:Number = 0;
		private var _insB:Number = 0;

		public function DialogLayer()
		{
			_scrim = new Sprite();
			_scrim.addEventListener(MouseEvent.CLICK, function(e:MouseEvent):void { cancel(); });
			addChild(_scrim);
			visible = false;
		}

		public function get isOpen():Boolean { return visible; }

		/** ins = system bars over the app ({t, b}); the card stays between them. */
		public function layout(w:Number, h:Number, ins:Object = null):void
		{
			_w = w;
			_h = h;
			_insT = ins ? ins.t : 0;
			_insB = ins ? ins.b : 0;
			_scrim.graphics.clear();
			_scrim.graphics.beginFill(0x000000, 0.45);
			_scrim.graphics.drawRect(0, 0, w, h);
			_scrim.graphics.endFill();
			placeCard();
		}

		public function cancel():void
		{
			var f:Function = _onCancel;
			close();
			if (f != null) f();
		}

		public function close():void
		{
			if (_card && _card.parent) removeChild(_card);
			_card = null;
			_onCancel = null;
			if (_input && stage && stage.focus == _input) stage.focus = null;
			_input = null;
			visible = false;
		}

		private function cardWidth():Number
		{
			return Math.min(_w - M.px(48), M.px(360));
		}

		private function begin(title:String):Sprite
		{
			if (_card) close();
			_card = new Sprite();
			addChild(_card);
			visible = true;
			if (title)
			{
				var t:TextField = M.text(title, 20, M.TEXT, true, cardWidth() - M.px(48), true);
				t.x = M.px(24);
				t.y = M.px(20);
				_card.addChild(t);
			}
			return _card;
		}

		private function finish(contentBottom:Number):void
		{
			var cw:Number = cardWidth();
			var bg:Shape = new Shape();
			bg.graphics.beginFill(M.SURFACE);
			bg.graphics.drawRoundRect(0, 0, cw, contentBottom, M.px(8), M.px(8));
			bg.graphics.endFill();
			M.elevate(bg, 12);
			bg.cacheAsBitmap = true;
			_card.addChildAt(bg, 0);
			placeCard();
		}

		private function placeCard():void
		{
			if (!_card) return;
			var cw:Number = cardWidth();
			var ch:Number = _card.numChildren > 0 ? _card.getChildAt(0).height : _card.height;
			_card.x = Math.round((_w - cw) / 2);
			var free:Number = _h - _insT - _insB;
			var y:Number = _insT + (free - ch) / 2;
			if (_input) y = Math.min(y, _insT + M.px(48)); // keep the text field above the soft keyboard
			_card.y = Math.round(Math.max(_insT + M.px(16), y));
		}

		private function titleBottom():Number
		{
			// called before the background is added: child 0 is the title (if any)
			return _card.numChildren > 0 ? _card.getChildAt(0).y + _card.getChildAt(0).height + M.px(12) : M.px(8);
		}

		/** List of choices; `selected` >= 0 shows radio buttons. callback(index). */
		public function showOptions(title:String, options:Array, selected:int, callback:Function, onCancel:Function = null):void
		{
			var card:Sprite = begin(title);
			_onCancel = onCancel;
			var cw:Number = cardWidth();
			var rowH:Number = M.px(48);
			var top:Number = titleBottom();
			var list:ScrollView = new ScrollView();
			// leave clear space above and below the card so its edges are visible
			// the whole card takes at most ~75% of the visible height (minus system bars)
			var free:Number = _h - _insT - _insB;
			var maxListH:Number = Math.floor(free * 0.75) - top - M.px(60);
			var listH:Number = Math.max(rowH * 2, Math.min(maxListH, options.length * rowH));
			list.y = top;
			list.setSize(cw, listH);
			card.addChild(list);

			for (var i:int = 0; i < options.length; i++)
			{
				var row:Sprite = makeOptionRow(String(options[i]), i, selected, cw, rowH, callback, list);
				row.y = i * rowH;
				list.content.addChild(row);
			}
			if (selected > 0) list.scrollTo(selected * rowH - listH / 2 + rowH / 2);

			var cancelBtn:TextButton = new TextButton("Cancel");
			cancelBtn.addEventListener(MouseEvent.CLICK, function(e:MouseEvent):void { cancel(); });
			cancelBtn.x = cw - cancelBtn.w - M.px(8);
			cancelBtn.y = top + listH + M.px(8);
			card.addChild(cancelBtn);
			finish(cancelBtn.y + cancelBtn.h + M.px(8));
		}

		private function makeOptionRow(label:String, index:int, selected:int, cw:Number, rowH:Number,
		                               callback:Function, list:ScrollView):Sprite
		{
			var row:Sprite = new Sprite();
			row.cacheAsBitmap = true;
			row.graphics.beginFill(0, 0);
			row.graphics.drawRect(0, 0, cw, rowH);
			row.graphics.endFill();
			row.mouseChildren = false;
			row.buttonMode = true;
			var tx:Number = M.px(24);
			if (selected >= 0)
			{
				var radio:Shape = new Shape();
				var on:Boolean = index == selected;
				radio.graphics.lineStyle(M.px(2), on ? M.ACCENT : M.TEXT2);
				radio.graphics.drawCircle(M.px(34), rowH / 2, M.px(9));
				if (on)
				{
					radio.graphics.lineStyle();
					radio.graphics.beginFill(M.ACCENT);
					radio.graphics.drawCircle(M.px(34), rowH / 2, M.px(5));
					radio.graphics.endFill();
				}
				row.addChild(radio);
				tx = M.px(68);
			}
			var tf:TextField = M.text("", 16, M.TEXT);
			M.fit(tf, label, cw - tx - M.px(16));
			tf.x = tx;
			tf.y = Math.round((rowH - tf.height) / 2);
			row.addChild(tf);
			row.addEventListener(MouseEvent.MOUSE_DOWN, function(e:MouseEvent):void {
				row.graphics.clear();
				row.graphics.beginFill(0x000000, 0.06);
				row.graphics.drawRect(0, 0, cw, rowH);
				row.graphics.endFill();
			});
			var clear:Function = function(e:MouseEvent):void {
				row.graphics.clear();
				row.graphics.beginFill(0, 0);
				row.graphics.drawRect(0, 0, cw, rowH);
				row.graphics.endFill();
			};
			row.addEventListener(MouseEvent.MOUSE_UP, clear);
			row.addEventListener(MouseEvent.ROLL_OUT, clear);
			row.addEventListener(MouseEvent.CLICK, function(e:MouseEvent):void {
				close();
				callback(index);
			});
			return row;
		}

		/** Message with OK / Cancel. callback(ok:Boolean). Pass cancelLabel = null for OK only. */
		public function showConfirm(title:String, message:String, okLabel:String, callback:Function,
		                            cancelLabel:String = "Cancel"):void
		{
			var card:Sprite = begin(title);
			_onCancel = function():void { callback(false); };
			var cw:Number = cardWidth();
			var y:Number = titleBottom();
			if (message)
			{
				var msg:TextField = M.text(message, 15, M.TEXT2, false, cw - M.px(48), true);
				msg.x = M.px(24);
				msg.y = y;
				card.addChild(msg);
				y += msg.height + M.px(16);
			}
			var ok:TextButton = new TextButton(okLabel);
			ok.addEventListener(MouseEvent.CLICK, function(e:MouseEvent):void { close(); callback(true); });
			ok.x = cw - ok.w - M.px(8);
			ok.y = y;
			card.addChild(ok);
			if (cancelLabel)
			{
				var no:TextButton = new TextButton(cancelLabel);
				no.addEventListener(MouseEvent.CLICK, function(e:MouseEvent):void { close(); callback(false); });
				no.x = ok.x - no.w - M.px(8);
				no.y = y;
				card.addChild(no);
			}
			finish(y + ok.h + M.px(8));
		}

		/** Single-line text input. callback(text) or callback(null) when cancelled. */
		public function showInput(title:String, value:String, hint:String, callback:Function):void
		{
			var card:Sprite = begin(title);
			_onCancel = function():void { callback(null); };
			var cw:Number = cardWidth();
			var y:Number = titleBottom();
			if (hint)
			{
				var h:TextField = M.text(hint, 13, M.TEXT2, false, cw - M.px(48), true);
				h.x = M.px(24);
				h.y = y;
				card.addChild(h);
				y += h.height + M.px(8);
			}
			var input:TextField = new TextField();
			input.defaultTextFormat = new TextFormat(M.FONT, Math.round(16 * M.dp), M.TEXT);
			input.type = TextFieldType.INPUT;
			input.needsSoftKeyboard = true;
			input.multiline = false;
			input.width = cw - M.px(48);
			input.height = M.px(28);
			input.x = M.px(24);
			input.y = y;
			input.text = value;
			card.addChild(input);
			_input = input;
			var line:Shape = new Shape();
			line.graphics.beginFill(M.ACCENT);
			line.graphics.drawRect(M.px(24), y + M.px(30), cw - M.px(48), M.px(2));
			line.graphics.endFill();
			card.addChild(line);
			y += M.px(44);

			var ok:TextButton = new TextButton("OK");
			ok.addEventListener(MouseEvent.CLICK, function(e:MouseEvent):void {
				var t:String = input.text;
				close();
				callback(t);
			});
			ok.x = cw - ok.w - M.px(8);
			ok.y = y;
			card.addChild(ok);
			var no:TextButton = new TextButton("Cancel");
			no.addEventListener(MouseEvent.CLICK, function(e:MouseEvent):void { close(); callback(null); });
			no.x = ok.x - no.w - M.px(8);
			no.y = y;
			card.addChild(no);
			finish(y + ok.h + M.px(8));
			if (stage)
			{
				stage.focus = input;
				input.setSelection(input.length, input.length);
				try { input.requestSoftKeyboard(); } catch (e:Error) {}
			}
		}
	}
}
