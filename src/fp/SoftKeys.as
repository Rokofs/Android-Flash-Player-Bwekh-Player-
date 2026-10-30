package fp
{
	import flash.display.DisplayObject;
	import flash.display.InteractiveObject;
	import flash.display.Sprite;
	import flash.events.Event;
	import flash.events.FocusEvent;
	import flash.events.KeyboardEvent;
	import flash.events.SoftKeyboardEvent;
	import flash.events.TextEvent;
	import flash.text.TextField;
	import flash.text.TextFieldType;
	import flash.utils.getQualifiedClassName;
	import flash.utils.getTimer;
	import flash.utils.setTimeout;

	/**
	 * The phone's keyboard for games.
	 *  - A game's own input text (a classic TextField): Android's keyboard is asked for when it
	 *    gets the focus; AIR does the typing.
	 *  - Everything else (a game that reads keys on the stage, TLF input text of Flash CS5): an
	 *    invisible text field of ours takes the keyboard, and every character typed in it goes to
	 *    the game as the key press a PC keyboard would make (KEY_DOWN / KEY_UP with keyCode and
	 *    charCode), and to TLF text as the text it inserts.
	 */
	public class SoftKeys
	{
		private var host:Sprite;
		private var proxy:TextField;
		/** send(code, charCode, down, shift): a key to the game, without moving the focus */
		private var send:Function;
		/** the keyboard closed: the game gets its focus back */
		private var onClosed:Function;
		/** TLF text the typing goes to (null: the game's keys) */
		private var tlf:InteractiveObject;
		private var _active:Boolean = false;
		private static const SENTINEL:String = "                ";

		public function SoftKeys(host:Sprite, send:Function, onClosed:Function)
		{
			this.host = host;
			this.send = send;
			this.onClosed = onClosed;
		}

		public function get active():Boolean { return _active; }

		/** when a finger last went down on the game's text to type in */
		private var tapAt:int = -100000;
		private var tapRoot:DisplayObject;

		/** a finger on the game (the player's capture listener): on its input text, the keyboard */
		public function tap(target:DisplayObject):void
		{
			var root:DisplayObject = editableRoot(target);
			if (!root)
			{
				tapAt = -100000;
				tapRoot = null;
				return;
			}
			tapAt = getTimer();
			tapRoot = root;
			// the focus moves on the mouse down; already there (a second tap): ask again
			setTimeout(function():void {
				var st:Object = host.stage;
				var f:InteractiveObject = st ? st.focus as InteractiveObject : null;
				if (f && editableRoot(f) == root) gameFocus(f, true);
			}, 30);
		}

		/**
		 * The game's focus moved here. The keyboard only for text to type in, and only when a finger
		 * put it there (user) — not when the game moves the focus by itself.
		 */
		public function gameFocus(io:InteractiveObject, user:Boolean = false):Boolean
		{
			if (!io || io == proxy) return false;
			var root:DisplayObject = editableRoot(io);
			if (!root) return false;
			if (!user && !(tapRoot == root && getTimer() - tapAt < 800)) return false;
			try
			{
				var first:Boolean = !io.needsSoftKeyboard;
				io.needsSoftKeyboard = true;
				if (first)
				{
					// AIR would raise it on every focus from now on: only after a tap
					io.addEventListener(SoftKeyboardEvent.SOFT_KEYBOARD_ACTIVATING, function(ae:SoftKeyboardEvent):void {
						if (getTimer() - tapAt > 1000 && getTimer() - userAt > 1000) ae.preventDefault();
					});
				}
				io.requestSoftKeyboard();
				if (first && io is TextField) Log.write("keyboard: for the game's text field " + io.name);
				if (first && !(io is TextField))
				{
					Log.write("keyboard: for the game's TLF text");
					// (the log says whether the runtime gives it the typing)
					var seen:Object = {};
					var probe:Function = function(pe:Event):void {
						var k:String = pe.type + (pe is KeyboardEvent ? " " + KeyboardEvent(pe).keyCode : "");
						if (seen[k]) return;
						seen[k] = true;
						Log.write("keyboard: TLF text got " + k + (pe is TextEvent ? " \"" + TextEvent(pe).text + "\"" : ""));
					};
					io.addEventListener(TextEvent.TEXT_INPUT, probe, true, 100);
					io.addEventListener(KeyboardEvent.KEY_DOWN, probe, true, 100);
					io.addEventListener(TextEvent.TEXT_INPUT, probe, false, 100);
					io.addEventListener(KeyboardEvent.KEY_DOWN, probe, false, 100);
				}
			}
			catch (e:Error) {}
			return true;
		}

		/** the "Keyboard" button: the game's focused text, if it has one */
		private var userAt:int = -100000;
		public function userOpen(io:InteractiveObject):Boolean
		{
			userAt = getTimer();
			return gameFocus(io, true);
		}

		/** the game's text to type in this belongs to: an input TextField, or an fl.text::TLFTextField of type "input" */
		private static function editableRoot(d:DisplayObject):DisplayObject
		{
			try
			{
				for (var i:int = 0; d && i < 6; i++, d = d.parent)
				{
					var tf:TextField = d as TextField;
					if (tf) return tf.type == TextFieldType.INPUT ? tf : null;
					if (getQualifiedClassName(d).indexOf("TLFTextField") >= 0)
						return String(Object(d).type) == "input" ? d : null;
				}
			}
			catch (e:Error) {}
			return null;
		}

		public function open(tlfTarget:InteractiveObject = null):void
		{
			tlf = tlfTarget;
			if (!proxy)
			{
				proxy = new TextField();
				proxy.type = TextFieldType.INPUT;
				proxy.multiline = false;
				proxy.width = 8;
				proxy.height = 8;
				proxy.alpha = 0;
				proxy.needsSoftKeyboard = true;
				proxy.addEventListener(TextEvent.TEXT_INPUT, onText);
				proxy.addEventListener(KeyboardEvent.KEY_DOWN, onKey);
				proxy.addEventListener(KeyboardEvent.KEY_UP, function(ke:KeyboardEvent):void { ke.stopImmediatePropagation(); });
				proxy.addEventListener(Event.CHANGE, onChange);
				proxy.addEventListener(SoftKeyboardEvent.SOFT_KEYBOARD_DEACTIVATE, onDeactivate);
				proxy.addEventListener(FocusEvent.FOCUS_OUT, onFocusOut);
			}
			if (!proxy.parent) host.addChild(proxy);
			proxy.x = 0;
			proxy.y = 0;
			reset();
			_active = true;
			try
			{
				if (host.stage) host.stage.focus = proxy;
				proxy.requestSoftKeyboard();
			}
			catch (e:Error) {}
			Log.write("keyboard: open" + (tlf ? " for TLF text " + getQualifiedClassName(tlf) : " for the game's keys"));
		}

		public function close():void
		{
			if (!_active) return;
			_active = false;
			tlf = null;
			if (proxy && proxy.parent) proxy.parent.removeChild(proxy);
			Log.write("keyboard: closed");
			if (onClosed != null) onClosed();
		}

		private function reset():void
		{
			proxy.text = SENTINEL;
			proxy.setSelection(SENTINEL.length, SENTINEL.length);
			last = SENTINEL;
		}

		/** what our field held after the last change */
		private var last:String = "";
		private var changed:Boolean = false;
		private var changedAt:int = -1000;

		/** typing goes into our field as usual (the keyboard's suggestions and corrections work on it) */
		private function onText(e:TextEvent):void
		{
		}

		/**
		 * The field changed: what was removed is Backspace presses, what was added is typed.
		 * (Comparing the text works for every keyboard: some send Backspace as a key, some only
		 * edit the text, some replace a whole word when they correct it.)
		 */
		private function onChange(e:Event):void
		{
			changed = true;
			changedAt = getTimer();
			var now:String = proxy.text;
			var n:int = 0;
			var max:int = Math.min(now.length, last.length);
			while (n < max && now.charCodeAt(n) == last.charCodeAt(n)) n++;
			var removed:int = last.length - n;
			var added:String = now.substr(n);
			last = now;
			for (var i:int = 0; i < removed; i++) press(8, 8, false);
			if (added.length)
			{
				if (tlf)
				{
					try { tlf.dispatchEvent(new TextEvent(TextEvent.TEXT_INPUT, true, true, added)); } catch (te:Error) {}
				}
				else
				{
					for (var j:int = 0; j < added.length; j++) typeChar(added.charAt(j));
				}
			}
			// keep something to delete, and the field short (not while a word is being typed)
			if (now.length < 4 || now.length > 200) reset();
		}

		/** Enter / arrows / Esc the keyboard sends as keys; Backspace only when our field is empty */
		private function onKey(e:KeyboardEvent):void
		{
			// our field's own key events stay ours: the game gets the ones we make
			e.stopImmediatePropagation();
			var c:uint = e.keyCode;
			if (c == 8)
			{
				// the text change does it; if none comes (nothing left to delete), the key does
				if (getTimer() - changedAt < 40) return; // the change came first
				changed = false;
				setTimeout(function():void {
					if (!changed && _active) { press(8, 8, false); reset(); }
				}, 60);
				return;
			}
			if (c == 13 || c == 9 || c == 27 || (c >= 37 && c <= 40) || c == 46)
				press(c, c == 13 ? 13 : 0, false);
		}

		private function onDeactivate(e:Event):void
		{
			close();
		}

		private function onFocusOut(e:FocusEvent):void
		{
			// a tap on the game: it gets the focus and the keyboard goes; the gamepad or nothing:
			// the typing goes on
			var to:InteractiveObject = e.relatedObject;
			setTimeout(function():void {
				if (!_active || !proxy || !proxy.stage) return;
				var now:InteractiveObject = proxy.stage.focus;
				if (now == proxy) return;
				if ((now && isGame != null && isGame(now)) || (to && isGame != null && isGame(to))) close();
				else try { proxy.stage.focus = proxy; } catch (fe:Error) {}
			}, 50);
		}

		/** isGame(object): it's in the game (set by the player) */
		public var isGame:Function;

		private function typeChar(ch:String):void
		{
			var k:Array = keyOf(ch);
			press(k[0], ch.charCodeAt(0), k[1]);
		}

		/** a short press: down now, up a moment later (games count keys held) */
		private function press(code:int, charCode:int, shift:Boolean):void
		{
			if (tlf)
			{
				// TLF edits on its own key handler (Backspace, Delete, arrows)
				try
				{
					tlf.dispatchEvent(new KeyboardEvent(KeyboardEvent.KEY_DOWN, true, true, charCode, code, 0, false, false, shift));
					tlf.dispatchEvent(new KeyboardEvent(KeyboardEvent.KEY_UP, true, true, charCode, code, 0, false, false, shift));
				}
				catch (e:Error) {}
				return;
			}
			send(code, charCode, true, shift);
			setTimeout(function():void { send(code, charCode, false, shift); }, 80);
		}

		/** [keyCode, shift] a PC keyboard gives for this character (Russian letters: the same keys) */
		public static function keyOf(ch:String):Array
		{
			var c:int = ch.charCodeAt(0);
			if (c >= 97 && c <= 122) return [c - 32, false];
			if (c >= 65 && c <= 90) return [c, true];
			if (c >= 48 && c <= 57) return [c, false];
			if (c == 32) return [32, false];
			var i:int = ")!@#$%^&*(".indexOf(ch);
			if (i >= 0) return [48 + i, true];
			var plain:String = ";=,-./`[\\]'";
			var shifted:String = ":+<_>?~{|}\"";
			var codes:Array = [186, 187, 188, 189, 190, 191, 192, 219, 220, 221, 222];
			i = plain.indexOf(ch);
			if (i >= 0) return [codes[i], false];
			i = shifted.indexOf(ch);
			if (i >= 0) return [codes[i], true];
			// ЙЦУКЕН on the QWERTY keys
			var ru:String = "йцукенгшщзхъфывапролджэячсмитьбюё";
			var en:String = "qwertyuiop[]asdfghjkl;'zxcvbnm,.`";
			var lower:String = ch.toLowerCase();
			i = ru.indexOf(lower);
			if (i >= 0)
			{
				var k:Array = keyOf(en.charAt(i));
				return [k[0], lower != ch];
			}
			return [0, false];
		}
	}
}
