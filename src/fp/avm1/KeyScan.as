package fp.avm1
{
	import flash.utils.ByteArray;
	import flash.utils.Dictionary;

	/**
	 * Which keyboard keys does AS1/AS2 code read? A quick look through the bytecode (nothing runs),
	 * so the on-screen gamepad can offer exactly those keys. Finds:
	 *   Key.isDown(68), Key.isDown(Key.LEFT)
	 *   Key.getCode() == 65, switch (Key.getCode()) { case 32: ... }
	 *   on (keyPress "<Left>") / on (keyPress "a")
	 * It follows pushes, variables, members and registers inside straight-line code; anything else
	 * just forgets what it knew, so a miss is possible but a wrong key is unlikely.
	 */
	public class KeyScan
	{
		private static const NAMED:Object = { BACKSPACE: 8, CAPSLOCK: 20, CONTROL: 17, DELETEKEY: 46, DOWN: 40, END: 35, ENTER: 13,
			ESCAPE: 27, HOME: 36, INSERT: 45, LEFT: 37, PGDN: 34, PGUP: 33, RIGHT: 39, SHIFT: 16, SPACE: 32, TAB: 9, UP: 38 };

		/** keyCode -> order of first appearance */
		private var found:Object = {};
		private var count:int = 0;

		public function KeyScan()
		{
		}

		/** key codes in the order the code first mentions them */
		public function get keys():Array
		{
			var r:Array = [];
			for (var k:String in found) r.push(int(k));
			r.sort(function(a:int, b:int):int { return found[a] - found[b]; });
			return r;
		}

		private function add(code:int):void
		{
			if (code < 8 || code > 222) return;
			if (code >= 97 && code <= 122) code -= 32; // a-z -> A-Z key codes
			if (found[code] === undefined) found[code] = count++;
		}

		/** on (keyPress ...) of a button */
		public function addKeyPress(kp:int):void
		{
			switch (kp)
			{
				case 1: add(37); return;  case 2: add(39); return;  case 3: add(36); return;  case 4: add(35); return;
				case 5: add(45); return;  case 6: add(46); return;  case 8: add(8); return;   case 13: add(13); return;
				case 14: add(38); return; case 15: add(40); return; case 16: add(33); return; case 17: add(34); return;
				case 18: add(9); return;  case 19: add(27); return;
			}
			if (kp >= 32 && kp < 127) add(kp);
		}

		public function scanAll(blocks:Dictionary):void
		{
			for (var k:* in blocks)
			{
				var b:ByteArray = k as ByteArray;
				if (b) scan(b);
			}
		}

		/** a value the scanner knows about: Number, String, or one of the tokens below */
		private static const KEY:Object = { t: "Key" };
		private static const GETCODE:Object = { t: "getCode" };
		private static const UNKNOWN:Object = { t: "?" };

		public function scan(code:ByteArray):void
		{
			try { scanBlock(code); } catch (e:Error) {}
		}

		private function scanBlock(b:ByteArray):void
		{
			var pool:Array = [];
			var st:Array = [];
			var regs:Object = {};
			var pc:int = 0;
			var n:int = b.length;
			var steps:int = 0;
			while (pc < n && steps++ < 2000000)
			{
				var op:int = b[pc];
				if (op == 0) { pc++; st.length = 0; continue; }
				var len:int = 0;
				var dataAt:int = pc + 1;
				if (op >= 0x80)
				{
					if (pc + 3 > n) return;
					len = b[pc + 1] | (b[pc + 2] << 8);
					dataAt = pc + 3;
				}
				var next:int = dataAt + len;
				switch (op)
				{
					case 0x88: // ConstantPool
					{
						pool = [];
						b.position = dataAt;
						var cnt:int = b[dataAt] | (b[dataAt + 1] << 8);
						var p:int = dataAt + 2;
						for (var i:int = 0; i < cnt && p < next; i++)
						{
							var s0:int = p;
							while (p < next && b[p] != 0) p++;
							b.position = s0;
							pool.push(b.readUTFBytes(p - s0));
							p++;
						}
						break;
					}
					case 0x96: // Push
					{
						var q:int = dataAt;
						while (q < next)
						{
							var t:int = b[q++];
							switch (t)
							{
								case 0:
									var s1:int = q;
									while (q < next && b[q] != 0) q++;
									b.position = s1;
									st.push(b.readUTFBytes(q - s1));
									q++;
									break;
								case 1:
									b.position = q; b.endian = "littleEndian";
									st.push(b.readFloat()); q += 4;
									break;
								case 2: case 3: st.push(UNKNOWN); break;
								case 4: var rv:* = regs[b[q++]]; st.push(rv === undefined ? UNKNOWN : rv); break;
								case 5: st.push(UNKNOWN); q++; break;
								case 6:
									// double, stored as two little-endian halves, high half first
									var d:ByteArray = new ByteArray(); d.endian = "littleEndian";
									d.writeBytes(b, q + 4, 4); d.writeBytes(b, q, 4); d.position = 0;
									st.push(d.readDouble()); q += 8;
									break;
								case 7:
									st.push(b[q] | (b[q + 1] << 8) | (b[q + 2] << 16) | (b[q + 3] << 24)); q += 4;
									break;
								case 8: st.push(pool[b[q]] !== undefined ? pool[b[q]] : UNKNOWN); q++; break;
								case 9: var ci:int = b[q] | (b[q + 1] << 8); st.push(pool[ci] !== undefined ? pool[ci] : UNKNOWN); q += 2; break;
								default: q = next; break;
							}
						}
						break;
					}
					case 0x1C: // GetVariable
					{
						var vn:* = st.pop();
						st.push(vn is String && (vn == "Key" || vn == "_global.Key") ? KEY : UNKNOWN);
						break;
					}
					case 0x4E: // GetMember
					{
						var mn:* = st.pop();
						var mo:* = st.pop();
						if (mo === KEY && mn is String && NAMED[String(mn).toUpperCase()] !== undefined) st.push(Number(NAMED[String(mn).toUpperCase()]));
						else st.push(UNKNOWN);
						break;
					}
					case 0x52: // CallMethod
					{
						var fname:* = st.pop();
						var obj:* = st.pop();
						var na:* = st.pop();
						var nargs:int = na is Number ? int(na) : -1;
						var args:Array = [];
						if (nargs < 0 || nargs > 64) { st.length = 0; break; }
						for (var j:int = 0; j < nargs; j++) args.push(st.length ? st.pop() : UNKNOWN);
						var res:Object = UNKNOWN;
						if (obj === KEY && fname is String)
						{
							var f:String = String(fname).toLowerCase();
							if (f == "isdown" && args.length && args[0] is Number) add(int(args[0]));
							else if (f == "getcode" || f == "getascii") res = GETCODE;
						}
						st.push(res);
						break;
					}
					case 0x87: // StoreRegister (value stays on the stack)
						regs[b[dataAt]] = st.length ? st[st.length - 1] : UNKNOWN;
						break;
					case 0x0E: case 0x49: case 0x66: // Equals, Equals2, StrictEquals
					{
						var x:* = st.pop();
						var y:* = st.pop();
						if (x === GETCODE && y is Number) add(int(y));
						else if (y === GETCODE && x is Number) add(int(x));
						st.push(UNKNOWN);
						break;
					}
					case 0x4C: // PushDuplicate
						st.push(st.length ? st[st.length - 1] : UNKNOWN);
						break;
					case 0x17: // Pop
						st.pop();
						break;
					case 0x9D: case 0x99: // If, Jump: values on the stack stay, straight-line knowledge is fine
						if (op == 0x9D) st.pop();
						break;
					case 0x9B: case 0x8E: // DefineFunction / DefineFunction2: the body follows inline
						st.length = 0;
						regs = {};
						break;
					default:
						st.length = 0;
						break;
				}
				if (st.length > 256) st.splice(0, st.length - 256);
				pc = next;
			}
		}
	}
}
