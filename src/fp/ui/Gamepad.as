package fp.ui
{
	import flash.display.Shape;
	import flash.display.Sprite;
	import flash.events.Event;
	import flash.events.MouseEvent;
	import flash.events.TouchEvent;
	import flash.geom.Point;
	import flash.system.Capabilities;
	import flash.text.TextField;
	import flash.utils.getTimer;
	import flash.utils.Dictionary;

	import fp.Keys;
	import fp.Settings;

	/**
	 * On-screen gamepad: a D-pad (arrows or WASD, diagonals supported) and up to four
	 * action buttons. Multi-touch. Calls sink(keyCode:int, down:Boolean) on every change.
	 */
	public class Gamepad extends Sprite
	{
		private var s:Settings;
		private var sink:Function;

		private var dpad:Sprite;
		private var dpadArt:Shape;
		private var btnLayer:Sprite;
		private var buttons:Array = [];  // {code, x, y, art:Shape, label:TextField}

		private var R:Number = 0;        // d-pad radius
		private var BR:Number = 0;       // button radius
		private var BD:Number = 0;       // button distance from cluster centre
		private var dpadCodes:Array = [38, 40, 37, 39]; // [up, down, left, right]
		private var built:Boolean = false;

		/** pointerId -> Array of key codes held by that pointer */
		private var pointers:Dictionary = new Dictionary();
		/** keyCode -> number of pointers holding it */
		private var held:Object = {};
		/** pointerId -> "dpad" | "btn": where the finger first touched */
		private var origins:Dictionary = new Dictionary();
		private var useTouch:Boolean;

		/** a held key repeats like a real keyboard (many old games move on "key down" events) */
		private static const REPEAT_DELAY:int = 350;
		private static const REPEAT_EVERY:int = 50;
		/** keyCode -> getTimer() of its next repeat */
		private var repeatAt:Object = {};

		public function Gamepad(settings:Settings, sink:Function)
		{
			s = settings;
			this.sink = sink;
			dpad = new Sprite();
			dpadArt = new Shape();
			dpad.addChild(dpadArt);
			addChild(dpad);
			btnLayer = new Sprite();
			addChild(btnLayer);

			useTouch = Capabilities.manufacturer.indexOf("Android") >= 0 || Capabilities.manufacturer.indexOf("iOS") >= 0;
			if (useTouch)
			{
				addEventListener(TouchEvent.TOUCH_BEGIN, onTouchBegin);
			}
			else
			{
				addEventListener(MouseEvent.MOUSE_DOWN, onMouseDown);
			}
			// don't let gamepad touches reach the game as clicks
			for each (var t:String in [MouseEvent.MOUSE_DOWN, MouseEvent.MOUSE_UP, MouseEvent.CLICK,
				MouseEvent.MOUSE_MOVE, TouchEvent.TOUCH_BEGIN, TouchEvent.TOUCH_END, TouchEvent.TOUCH_MOVE, TouchEvent.TOUCH_TAP])
			{
				addEventListener(t, stopBubble);
			}
			addEventListener(Event.ENTER_FRAME, onRepeat);
			addEventListener(Event.ADDED_TO_STAGE, onAdded);
			addEventListener(Event.REMOVED_FROM_STAGE, onRemoved);
			rebuild();
		}

		private function stopBubble(e:Event):void
		{
			e.stopPropagation();
		}

		/** Width each cluster needs from the screen edge . */
		public function get sideWidth():Number
		{
			return Math.max(R * 2, BD * 2 + BR * 2) + M.px(32);
		}

		/** keys for this game (Settings.padLayout); null = the user's layout */
		public var keyLayout:Object;

		public function rebuild():void
		{
			releaseAll();
			var sc:Number = s.gamepadScale;
			if (!(sc > 0)) sc = 1;
			R = M.px(68) * sc;
			BR = M.px(30) * sc;
			BD = M.px(50) * sc;
			var lay:Object = keyLayout || s.padLayout(null);
			dpadCodes = lay.dpad.concat();
			alpha = s.gamepadOpacity > 0 ? s.gamepadOpacity : 0.5;
			buildArrows();

			btnLayer.removeChildren();
			buttons = [];
			var pos:Array = [[0, 1], [1, 0], [-1, 0], [0, -1]]; // A bottom, B right, C left, D top
			for (var i:int = 0; i < 4; i++)
			{
				var code:int = lay.buttons[i];
				if (code == 0) continue;
				var art:Shape = new Shape();
				var tf:TextField = M.text(Keys.label(code), 15 * sc, 0xFFFFFF, true);
				var b:Object = { code: code, x: pos[i][0] * BD, y: pos[i][1] * BD, art: art, label: tf };
				art.x = b.x;
				art.y = b.y;
				tf.x = b.x - tf.width / 2;
				tf.y = b.y - tf.height / 2;
				btnLayer.addChild(art);
				btnLayer.addChild(tf);
				buttons.push(b);
			}
			built = true;
			redraw();
		}

		public function layout(w:Number, h:Number, ins:Object = null):void
		{
			if (!ins) ins = { l: 0, t: 0, r: 0, b: 0 };
			var margin:Number = M.px(20);
			var leftX:Number = ins.l + margin + Math.max(R, BD + BR);
			var rightX:Number = w - ins.r - margin - Math.max(R, BD + BR);
			var cy:Number = h - ins.b - margin - Math.max(R, BD + BR);
			if (s.gamepadSwap)
			{
				dpad.x = rightX; btnLayer.x = leftX;
			}
			else
			{
				dpad.x = leftX; btnLayer.x = rightX;
			}
			dpad.y = cy;
			btnLayer.y = cy;
		}

		private function onRepeat(e:Event):void
		{
			var now:int = getTimer();
			for (var k:String in repeatAt)
			{
				if (!(held[k] > 0)) { delete repeatAt[k]; continue; }
				if (now >= repeatAt[k])
				{
					repeatAt[k] = now + REPEAT_EVERY;
					sink(int(k), true);
				}
			}
		}

		public function releaseAll():void
		{
			for (var k:String in held)
			{
				if (held[k] > 0) sink(int(k), false);
			}
			held = {};
			repeatAt = {};
			pointers = new Dictionary();
			origins = new Dictionary();
			if (built) redraw(); // nothing to draw before rebuild() has computed the sizes
		}

		// --------------------------------------------------------------- input

		private function onAdded(e:Event):void
		{
			if (useTouch)
			{
				stage.addEventListener(TouchEvent.TOUCH_MOVE, onTouchMove, true);
				stage.addEventListener(TouchEvent.TOUCH_END, onTouchEnd, true);
			}
			else
			{
				stage.addEventListener(MouseEvent.MOUSE_MOVE, onMouseMove, true);
				stage.addEventListener(MouseEvent.MOUSE_UP, onMouseUp, true);
			}
			stage.addEventListener(Event.DEACTIVATE, onDeactivate);
		}

		private function onRemoved(e:Event):void
		{
			releaseAll();
			stage.removeEventListener(TouchEvent.TOUCH_MOVE, onTouchMove, true);
			stage.removeEventListener(TouchEvent.TOUCH_END, onTouchEnd, true);
			stage.removeEventListener(MouseEvent.MOUSE_MOVE, onMouseMove, true);
			stage.removeEventListener(MouseEvent.MOUSE_UP, onMouseUp, true);
			stage.removeEventListener(Event.DEACTIVATE, onDeactivate);
		}

		private function onDeactivate(e:Event):void
		{
			releaseAll();
		}

		private function onTouchBegin(e:TouchEvent):void { pointer(e.touchPointID, e.stageX, e.stageY, true); }
		private function onTouchMove(e:TouchEvent):void { if (pointers[e.touchPointID]) pointer(e.touchPointID, e.stageX, e.stageY, false); }
		private function onTouchEnd(e:TouchEvent):void { endPointer(e.touchPointID); }
		private function onMouseDown(e:MouseEvent):void { pointer(-1, e.stageX, e.stageY, true); }
		private function onMouseMove(e:MouseEvent):void { if (pointers[-1]) pointer(-1, e.stageX, e.stageY, false); }
		private function onMouseUp(e:MouseEvent):void { endPointer(-1); }

		private function pointer(id:int, sx:Number, sy:Number, begin:Boolean):void
		{
			if (begin) origins[id] = onDpadArea(sx, sy, 1.15) ? "dpad" : "btn";
			var codes:Array = codesAt(sx, sy, origins[id]);
			var old:Array = pointers[id] as Array || [];
			pointers[id] = codes;
			apply(old, codes);
		}

		private function endPointer(id:int):void
		{
			var old:Array = pointers[id] as Array;
			if (!old) return;
			delete pointers[id];
			delete origins[id];
			apply(old, []);
		}

		private function apply(old:Array, now:Array):void
		{
			var code:int;
			var changed:Boolean = false;
			for each (code in old)
			{
				if (now.indexOf(code) < 0)
				{
					held[code] = (held[code] || 1) - 1;
					if (held[code] <= 0)
					{
						delete held[code];
						delete repeatAt[code];
						sink(code, false);
					}
					changed = true;
				}
			}
			for each (code in now)
			{
				if (old.indexOf(code) < 0)
				{
					held[code] = (held[code] || 0) + 1;
					if (held[code] == 1)
					{
						sink(code, true);
						repeatAt[code] = getTimer() + REPEAT_DELAY;
					}
					changed = true;
				}
			}
			if (changed) redraw();
		}

		private function onDpadArea(sx:Number, sy:Number, factor:Number):Boolean
		{
			var p:Point = dpad.globalToLocal(new Point(sx, sy));
			return Math.sqrt(p.x * p.x + p.y * p.y) <= R * factor;
		}

		/** Which keys a finger at stage point (sx, sy) presses; origin = where it first touched. */
		private function codesAt(sx:Number, sy:Number, origin:String):Array
		{
			if (origin == "dpad")
			{
				var p:Point = dpad.globalToLocal(new Point(sx, sy));
				var dist:Number = Math.sqrt(p.x * p.x + p.y * p.y);
				var res:Array = [];
				if (dist < R * 0.22 || dist > R * 2.5) return res; // dead zone / finger slid far away
				var t:Number = R * 0.38;
				if (p.y < -t) res.push(dpadCodes[0]);
				if (p.y > t) res.push(dpadCodes[1]);
				if (p.x < -t) res.push(dpadCodes[2]);
				if (p.x > t) res.push(dpadCodes[3]);
				if (res.length == 0)
				{
					// between thresholds: pick the dominant axis
					if (Math.abs(p.x) > Math.abs(p.y)) res.push(p.x < 0 ? dpadCodes[2] : dpadCodes[3]);
					else res.push(p.y < 0 ? dpadCodes[0] : dpadCodes[1]);
				}
				return res;
			}
			var q:Point = btnLayer.globalToLocal(new Point(sx, sy));
			var best:Object = null;
			var bestD:Number = Number.MAX_VALUE;
			for each (var b:Object in buttons)
			{
				var dx:Number = q.x - b.x, dy:Number = q.y - b.y;
				var d:Number = Math.sqrt(dx * dx + dy * dy);
				if (d < bestD)
				{
					bestD = d;
					best = b;
				}
			}
			if (best && bestD <= BR * 1.35) return [best.code];
			return [];
		}

		// --------------------------------------------------------------- drawing

		private function isHeld(code:int):Boolean
		{
			return held[code] > 0;
		}

		private static const DIRS:Array = [[0, -1, "arrowUp"], [0, 1, "arrowDown"], [-1, 0, "arrowLeft"], [1, 0, "arrowRight"]];

		/** Arrow glyphs are separate shapes so redraw() only repaints the fills. */
		private function buildArrows():void
		{
			while (dpad.numChildren > 1) dpad.removeChildAt(1);
			var arm:Number = R * 0.42;
			for (var i:int = 0; i < 4; i++)
			{
				var a:Shape = Icons.shape(DIRS[i][2], arm * 1.2, 0xFFFFFF, 0.95);
				a.x = DIRS[i][0] * R * 0.58 - arm * 0.6;
				a.y = DIRS[i][1] * R * 0.58 - arm * 0.6;
				dpad.addChild(a);
			}
		}

		private function redraw():void
		{
			// invisible hit area slightly larger than the art
			dpad.graphics.clear();
			dpad.graphics.beginFill(0, 0);
			dpad.graphics.drawCircle(0, 0, R * 1.15);
			dpad.graphics.endFill();

			var g:* = dpadArt.graphics;
			g.clear();
			g.beginFill(0x000000, 0.35);
			g.drawCircle(0, 0, R);
			g.endFill();
			g.lineStyle(M.px(2), 0xFFFFFF, 0.6);
			g.drawCircle(0, 0, R);
			g.lineStyle();
			var arm:Number = R * 0.42;
			for (var i:int = 0; i < 4; i++)
			{
				var on:Boolean = isHeld(dpadCodes[i]);
				g.beginFill(on ? M.ACCENT : 0xFFFFFF, on ? 0.95 : 0.2);
				g.drawCircle(DIRS[i][0] * R * 0.58, DIRS[i][1] * R * 0.58, arm);
				g.endFill();
			}

			btnLayer.graphics.clear();
			for each (var b:Object in buttons)
			{
				var bon:Boolean = isHeld(b.code);
				var art:Shape = b.art;
				art.graphics.clear();
				art.graphics.beginFill(bon ? M.ACCENT : 0x000000, bon ? 0.95 : 0.35);
				art.graphics.drawCircle(0, 0, BR);
				art.graphics.endFill();
				art.graphics.lineStyle(M.px(2), 0xFFFFFF, 0.6);
				art.graphics.drawCircle(0, 0, BR);
				btnLayer.graphics.beginFill(0, 0);
				btnLayer.graphics.drawCircle(b.x, b.y, BR * 1.3);
				btnLayer.graphics.endFill();
			}
		}
	}
}
