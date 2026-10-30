package fp.avm1
{
	import flash.utils.ByteArray;
	import flash.utils.Endian;

	/**
	 * Undoes the AS2 "flattened state machine" obfuscation (945a's Moyea FLV player, rga / box10):
	 *  - every code block is a while(true) dispatcher on a variable "\x01" whose start value comes
	 *    from a helper function "\x04\x05" (sets "\x03" and returns it)
	 *  - fake conditions through junk variables ("\x0f" = 1, !eval("\x0f")), junk pushes
	 *  - pieces of code hidden in the bytes of other tags (jumps out of the block), constant pools
	 *    switched on the way
	 *
	 * A partial evaluator walks each block: values known before the game runs (constants, the
	 * obfuscator's control-character variables) are computed here and dropped; instructions that
	 * work on the game's real data are written out in order, branches on real data kept. The
	 * result is plain linear code with one constant pool, put into a copy of the SWF body.
	 *
	 * run() returns the new body (the SWF without its 8-byte header), or null when the file isn't
	 * obfuscated or a block couldn't be decoded (then the original is used: the engine runs it too).
	 * (tools/as2-deob/deob.py is the same thing as a desktop tool.)
	 */
	public class Deobfuscator
	{
		/** what happened (for the log) */
		public static var info:String = "";

		private static const LIMIT:int = 400000;

		// ops that only compute from their inputs: code -> number of inputs (1 output)
		private static const PURE:Object = { 0x0a: 2, 0x0b: 2, 0x0c: 2, 0x0d: 2, 0x3f: 2, 0x47: 2, 0x0e: 2, 0x0f: 2,
			0x48: 2, 0x67: 2, 0x49: 2, 0x66: 2, 0x10: 2, 0x11: 2, 0x12: 1, 0x13: 2, 0x29: 2, 0x68: 2, 0x21: 2,
			0x14: 1, 0x31: 1, 0x18: 1, 0x4a: 1, 0x4b: 1, 0x50: 1, 0x51: 1, 0x60: 2, 0x61: 2, 0x62: 2, 0x63: 2,
			0x64: 2, 0x65: 2, 0x32: 1, 0x33: 1, 0x44: 1 };

		// fixed stack effects of the other ops: code -> [pops, pushes]
		private static const FIXED:Object = { 0x04: [0, 0], 0x05: [0, 0], 0x06: [0, 0], 0x07: [0, 0], 0x08: [0, 0],
			0x09: [0, 0], 0x15: [3, 1], 0x35: [3, 1], 0x36: [1, 1], 0x37: [1, 1], 0x1c: [1, 1], 0x1d: [2, 0],
			0x20: [1, 0], 0x22: [2, 1], 0x23: [3, 0], 0x24: [3, 0], 0x25: [1, 0], 0x26: [1, 0], 0x28: [0, 0],
			0x2a: [1, 0], 0x2b: [2, 1], 0x30: [1, 1], 0x34: [0, 1], 0x3a: [2, 1], 0x3b: [1, 1], 0x3c: [2, 0],
			0x41: [1, 0], 0x45: [1, 1], 0x4e: [2, 1], 0x4f: [3, 0], 0x54: [2, 1], 0x69: [2, 0], 0x81: [0, 0],
			0x83: [0, 0], 0x87: [0, 0], 0x8b: [0, 0], 0x8c: [0, 0], 0x9a: [2, 0], 0x9e: [1, 0], 0x9f: [1, 0],
			0x94: [1, 0], 0x17: [1, 0] };

		private static const UNDEF:Object = { t: "undef", x: null };

		private var b:ByteArray;
		private var version:int;
		private var done:int = 0;

		public function Deobfuscator(body:ByteArray, version:int)
		{
			b = body;
			b.endian = Endian.LITTLE_ENDIAN;
			this.version = version;
		}

		// ================================================================= entry

		public static function run(body:ByteArray, version:int):ByteArray
		{
			info = "";
			if (!body || body.length < 16) return null;
			var d:Deobfuscator = new Deobfuscator(body, version);
			var nb:int = body[0] >> 3;
			var hdr:int = int((5 + nb * 4 + 7) / 8) + 4;
			if (!d.anyObfuscated(hdr, body.length)) return null;
			try
			{
				var tags:ByteArray = d.rewrite(hdr, body.length);
				var out:ByteArray = new ByteArray();
				out.endian = Endian.LITTLE_ENDIAN;
				out.writeBytes(body, 0, hdr);
				out.writeBytes(tags);
				out.position = 0;
				info = "AS2 code de-obfuscated: " + d.done + " blocks";
				return out;
			}
			catch (e:Bail)
			{
				info = "obfuscated AS2 code, not decoded (" + e.message + "): running it as it is";
			}
			catch (e2:Error)
			{
				info = "obfuscated AS2 code, decoder error " + e2.message + ": running it as it is";
			}
			return null;
		}

		/** the obfuscator's dispatcher: Push "\x01" (96 03 00 00 01 00) */
		private function looksObfuscated(from:int, to:int):Boolean
		{
			for (var i:int = from; i + 5 < to; i++)
				if (b[i] == 0x96 && b[i + 1] == 3 && b[i + 2] == 0 && b[i + 3] == 0 && b[i + 4] == 1 && b[i + 5] == 0) return true;
			return false;
		}

		private function anyObfuscated(pos:int, end:int):Boolean
		{
			while (pos + 2 <= end)
			{
				var h:int = b[pos] | (b[pos + 1] << 8);
				var code:int = h >> 6, ln:int = h & 63, p:int = pos + 2;
				if (ln == 63) { if (p + 4 > end) return false; b.position = p; ln = b.readUnsignedInt(); p += 4; }
				if (p + ln > end) return false;
				if (code == 12 || code == 59 || code == 26 || code == 70 || code == 34)
				{
					if (looksObfuscated(p, p + ln)) return true;
				}
				else if (code == 39 && ln > 4)
				{
					if (anyObfuscated(p + 4, p + ln)) return true;
				}
				pos = p + ln;
				if (code == 0) break;
			}
			return false;
		}

		// ================================================================= tags

		private function rewrite(pos:int, end:int):ByteArray
		{
			var out:ByteArray = new ByteArray();
			out.endian = Endian.LITTLE_ENDIAN;
			while (pos + 2 <= end)
			{
				var tpos:int = pos;
				var h:int = b[pos] | (b[pos + 1] << 8);
				var code:int = h >> 6, ln:int = h & 63, p:int = pos + 2;
				if (ln == 63) { b.position = p; ln = b.readUnsignedInt(); p += 4; }
				if (p + ln > end) throw new Bail("tag past the end");
				pos = p + ln;
				var body:ByteArray = null;
				if ((code == 12 || code == 59) && looksObfuscated(p, p + ln))
				{
					var off:int = p + (code == 59 ? 2 : 0);
					body = new ByteArray();
					if (code == 59) body.writeBytes(b, p, 2);
					body.writeBytes(block(off));
					done++;
				}
				else if ((code == 26 || code == 70) && (b[p] & 0x80) && looksObfuscated(p, p + ln))
				{
					body = placeActions(p, ln, code == 70);
				}
				else if (code == 34 && looksObfuscated(p, p + ln))
				{
					body = button2Actions(p, ln);
				}
				else if (code == 39 && ln > 4 && anyObfuscated(p + 4, p + ln))
				{
					body = new ByteArray();
					body.writeBytes(b, p, 4);
					body.writeBytes(rewrite(p + 4, p + ln));
				}
				if (body) writeTag(out, code, body);
				else out.writeBytes(b, tpos, p + ln - tpos);
				if (code == 0) break;
			}
			return out;
		}

		private static function writeTag(out:ByteArray, code:int, body:ByteArray):void
		{
			if (body.length < 63) out.writeShort((code << 6) | body.length);
			else { out.writeShort((code << 6) | 63); out.writeUnsignedInt(body.length); }
			out.writeBytes(body);
		}

		private function placeActions(p:int, ln:int, po3:Boolean):ByteArray
		{
			var q:int = p;
			var f:int = b[q++];
			var f2:int = 0;
			if (po3) f2 = b[q++];
			q += 2; // depth
			if (po3 && ((f2 & 0x08) || ((f2 & 0x10) && (f & 0x02)))) q = zeroAfter(q);
			if (f & 0x02) q += 2;
			if (f & 0x04) q = skipMatrix(q);
			if (f & 0x08) q = skipCxform(q);
			if (f & 0x10) q += 2;
			if (f & 0x20) q = zeroAfter(q);
			if (f & 0x40) q += 2;
			if (po3 && (f2 & 0x01)) return null; // filters: not read here
			if (po3 && (f2 & 0x02)) q++;
			if (po3 && (f2 & 0x04)) q++;
			var out:ByteArray = new ByteArray();
			out.endian = Endian.LITTLE_ENDIAN;
			out.writeBytes(b, p, q - p);
			var w:int = version >= 6 ? 4 : 2;
			out.writeBytes(b, q, 2 + w);
			q += 2 + w;
			var end:int = p + ln;
			while (q < end)
			{
				var any:Boolean = false;
				for (var i:int = 0; i < w; i++) if (b[q + i]) any = true;
				if (!any) { out.writeBytes(b, q, w); q += w; break; }
				var flagsAt:int = q;
				q += w;
				b.position = q;
				var size:int = b.readUnsignedInt();
				q += 4;
				var codeAt:int = q;
				var key:Boolean = w == 4 && (b[flagsAt + 2] & 0x02) != 0;
				if (key) codeAt++;
				var nb:ByteArray = looksObfuscated(codeAt, q + size) ? block(codeAt) : null;
				if (nb) done++;
				out.writeBytes(b, flagsAt, w);
				var blen:int = (key ? 1 : 0) + (nb ? nb.length : q + size - codeAt);
				out.writeUnsignedInt(blen);
				if (key) out.writeByte(b[q]);
				if (nb) out.writeBytes(nb); else out.writeBytes(b, codeAt, q + size - codeAt);
				q += size;
			}
			if (q < end) out.writeBytes(b, q, end - q);
			return out;
		}

		private function button2Actions(p:int, ln:int):ByteArray
		{
			var q:int = p + 3;
			var off:int = b[q] | (b[q + 1] << 8);
			if (!off) return null;
			var a:int = q + off;
			var out:ByteArray = new ByteArray();
			out.endian = Endian.LITTLE_ENDIAN;
			out.writeBytes(b, p, a - p);
			var end:int = p + ln;
			while (a < end)
			{
				var size:int = b[a] | (b[a + 1] << 8);
				var stop:int = size ? a + size : end;
				var nb:ByteArray = looksObfuscated(a + 4, stop) ? block(a + 4) : null;
				if (nb) done++;
				var blen:int = nb ? nb.length : stop - a - 4;
				out.writeShort(size ? 4 + blen : 0);
				out.writeBytes(b, a + 2, 2);
				if (nb) out.writeBytes(nb); else out.writeBytes(b, a + 4, stop - a - 4);
				if (!size) break;
				a = stop;
			}
			return out;
		}

		private var bitPos:int;

		private function bits(n:int):int
		{
			var v:int = 0;
			for (var i:int = 0; i < n; i++, bitPos++)
				v = (v << 1) | ((b[bitPos >> 3] >> (7 - (bitPos & 7))) & 1);
			return v;
		}

		private function skipMatrix(q:int):int
		{
			bitPos = q * 8;
			var n:int;
			if (bits(1)) { n = bits(5); bits(n); bits(n); }
			if (bits(1)) { n = bits(5); bits(n); bits(n); }
			n = bits(5); bits(n); bits(n);
			return (bitPos + 7) >> 3;
		}

		private function skipCxform(q:int):int
		{
			bitPos = q * 8;
			var ha:int = bits(1), hm:int = bits(1), n:int = bits(4);
			if (hm) { bits(n); bits(n); bits(n); bits(n); }
			if (ha) { bits(n); bits(n); bits(n); bits(n); }
			return (bitPos + 7) >> 3;
		}

		private function zeroAfter(q:int):int
		{
			while (q < b.length && b[q] != 0) q++;
			return q + 1;
		}

		// ================================================================= one block

		private function block(start:int):ByteArray
		{
			var u:Unit = new Unit(this, start, null, 0);
			var items:Array = u.run(-1);
			var last:Object = items.length ? items[items.length - 1] : null;
			if (!last || last.k != "op" || last.c != 0) items.push({ k: "op", c: 0, d: null });
			return assemble(peephole(items));
		}

		// ---- reading actions
		public function opAt(pc:int):*
		{
			if (pc < 0 || pc >= b.length) throw new Bail("code outside the file at " + pc);
			var o:Op = new Op();
			o.pc = pc;
			o.code = b[pc];
			if (o.code < 0x80) { o.len = 0; o.end = pc + 1; return o; }
			if (pc + 3 > b.length) throw new Bail("cut action");
			o.len = b[pc + 1] | (b[pc + 2] << 8);
			o.data = pc + 3;
			o.end = pc + 3 + o.len;
			if (o.end > b.length) throw new Bail("cut action");
			return o;
		}

		public function u8(p:int):int { return b[p]; }
		public function u16(p:int):int { return b[p] | (b[p + 1] << 8); }

		public function cstr(p:int):Array
		{
			var s:String = "";
			var parts:Array = [];
			var q:int = p;
			while (q < b.length && b[q] != 0) q++;
			if (q >= b.length) throw new Bail("string past the end");
			// bytes as char codes (byte-transparent: written back the same way)
			for (var i:int = p; i < q; i += 512)
			{
				var n:int = Math.min(512, q - i);
				var codes:Array = new Array(n);
				for (var j:int = 0; j < n; j++) codes[j] = b[i + j];
				parts.push(String.fromCharCode.apply(null, codes));
			}
			s = parts.join("");
			return [s, q + 1];
		}

		public function pushValues(o:*, pool:Array):Array
		{
			var out:Array = [];
			var p:int = o.data, end:int = o.end;
			while (p < end)
			{
				var t:int = b[p++];
				if (t == 0) { var r:Array = cstr(p); out.push({ t: "str", x: r[0] }); p = r[1]; }
				else if (t == 1) { b.position = p; out.push({ t: "num", x: Number(b.readFloat()) }); p += 4; }
				else if (t == 2) out.push({ t: "null", x: null });
				else if (t == 3) out.push(UNDEF);
				else if (t == 4) out.push({ t: "reg", x: b[p++] });
				else if (t == 5) out.push({ t: "bool", x: b[p++] != 0 });
				else if (t == 6)
				{
					var tmp:ByteArray = new ByteArray();
					tmp.endian = Endian.LITTLE_ENDIAN;
					tmp.writeBytes(b, p + 4, 4);
					tmp.writeBytes(b, p, 4);
					tmp.position = 0;
					out.push({ t: "num", x: tmp.readDouble() });
					p += 8;
				}
				else if (t == 7) { b.position = p; out.push({ t: "num", x: Number(b.readInt()) }); p += 4; }
				else if (t == 8 || t == 9)
				{
					var k:int = t == 8 ? b[p] : u16(p);
					p += t == 8 ? 1 : 2;
					if (!pool || k >= pool.length) throw new Bail("pool ref " + k);
					out.push({ t: "str", x: pool[k] });
				}
				else throw new Bail("bad push type " + t);
			}
			return out;
		}

		public function parsePool(o:*):Array
		{
			var n:int = u16(o.data);
			var p:int = o.data + 2;
			var r:Array = [];
			for (var i:int = 0; i < n; i++) { var s:Array = cstr(p); r.push(s[0]); p = s[1]; }
			return r;
		}

		public static function target(o:*, buf:Deobfuscator):int
		{
			var off:int = buf.u16(o.data);
			if (off & 0x8000) off -= 0x10000;
			return o.end + off;
		}

		/** DefineFunction(2): [name, bodyLength] */
		public function funcInfo(o:*):Array
		{
			var r:Array = cstr(o.data);
			var name:String = r[0];
			var p:int = r[1];
			var n:int = u16(p); p += 2;
			if (o.code == 0x9b)
			{
				for (var i:int = 0; i < n; i++) p = cstr(p)[1];
			}
			else
			{
				p += 3;
				for (var j:int = 0; j < n; j++) { p++; p = cstr(p)[1]; }
			}
			return [name, u16(p)];
		}

		public function bytes(from:int, len:int):ByteArray
		{
			var r:ByteArray = new ByteArray();
			r.endian = Endian.LITTLE_ENDIAN;
			if (len > 0) r.writeBytes(b, from, len);
			return r;
		}

		// ================================================================= values

		public static function isObfName(s:String):Boolean
		{
			if (!s) return false;
			for (var i:int = 0; i < s.length; i++) if (s.charCodeAt(i) >= 0x20) return false;
			return true;
		}

		public static function toNum(v:Object):Number
		{
			switch (v.t)
			{
				case "num": return v.x;
				case "bool": return v.x ? 1 : 0;
				case "null": return 0;
				case "str":
					var s:String = String(v.x).replace(/^\s+|\s+$/g, "");
					return s == "" ? 0 : Number(s);
			}
			return NaN;
		}

		public static function toStr(v:Object):String
		{
			switch (v.t)
			{
				case "str": return v.x;
				case "bool": return v.x ? "true" : "false";
				case "null": return "null";
				case "undef": return "undefined";
				case "num": return String(v.x);
			}
			throw new Bail("toStr " + v.t);
		}

		public static function toBool(v:Object):Boolean
		{
			switch (v.t)
			{
				case "bool": return v.x;
				case "num": return !(v.x == 0 || isNaN(v.x));
				case "str": return v.x != "";
			}
			return false;
		}

		public static function toI32(v:Object):int
		{
			var n:Number = toNum(v);
			if (isNaN(n) || !isFinite(n)) return 0;
			return int(n);
		}

		private static function num(x:Number):Object { return { t: "num", x: x }; }
		private static function bool(x:Boolean):Object { return { t: "bool", x: x }; }

		public static function same(a:Object, c:Object):Boolean
		{
			return a.t == c.t && (a.x === c.x || (a.t == "num" && isNaN(a.x) && isNaN(c.x)));
		}

		public static function pureOp(code:int, a:Array):Object
		{
			var x:Number, y:Number;
			switch (code)
			{
				case 0x0a: return num(toNum(a[0]) + toNum(a[1]));
				case 0x0b: return num(toNum(a[0]) - toNum(a[1]));
				case 0x0c: return num(toNum(a[0]) * toNum(a[1]));
				case 0x0d: return num(toNum(a[0]) / toNum(a[1]));
				case 0x3f: return num(toNum(a[0]) % toNum(a[1]));
				case 0x47:
					if (a[0].t == "str" || a[1].t == "str") return { t: "str", x: toStr(a[0]) + toStr(a[1]) };
					return num(toNum(a[0]) + toNum(a[1]));
				case 0x0e: return bool(toNum(a[0]) == toNum(a[1]));
				case 0x0f: return bool(toNum(a[0]) < toNum(a[1]));
				case 0x48:
				case 0x67:
					if (a[0].t == "str" && a[1].t == "str") return bool(code == 0x48 ? a[0].x < a[1].x : a[0].x > a[1].x);
					x = toNum(a[0]); y = toNum(a[1]);
					if (isNaN(x) || isNaN(y)) return UNDEF;
					return bool(code == 0x48 ? x < y : x > y);
				case 0x49:
					if (a[0].t == a[1].t) return bool(a[0].x === a[1].x);
					var nul0:Boolean = a[0].t == "null" || a[0].t == "undef", nul1:Boolean = a[1].t == "null" || a[1].t == "undef";
					if (nul0 && nul1) return bool(true);
					if (nul0 || nul1) return bool(false);
					return bool(toNum(a[0]) == toNum(a[1]));
				case 0x66: return bool(a[0].t == a[1].t && a[0].x === a[1].x);
				case 0x10: return bool(toBool(a[0]) && toBool(a[1]));
				case 0x11: return bool(toBool(a[0]) || toBool(a[1]));
				case 0x12: return bool(!toBool(a[0]));
				case 0x13: return bool(toStr(a[0]) == toStr(a[1]));
				case 0x29: return bool(toStr(a[0]) < toStr(a[1]));
				case 0x68: return bool(toStr(a[0]) > toStr(a[1]));
				case 0x21: return { t: "str", x: toStr(a[0]) + toStr(a[1]) };
				case 0x14:
				case 0x31: return num(toStr(a[0]).length);
				case 0x18: x = toNum(a[0]); return num(isNaN(x) ? 0 : (x < 0 ? Math.ceil(x) : Math.floor(x)));
				case 0x4a: return num(toNum(a[0]));
				case 0x4b: return { t: "str", x: toStr(a[0]) };
				case 0x50: return num(toNum(a[0]) + 1);
				case 0x51: return num(toNum(a[0]) - 1);
				case 0x60: return num(toI32(a[0]) & toI32(a[1]));
				case 0x61: return num(toI32(a[0]) | toI32(a[1]));
				case 0x62: return num(toI32(a[0]) ^ toI32(a[1]));
				case 0x63: return num(toI32(a[0]) << (toI32(a[1]) & 31));
				case 0x64: return num(toI32(a[0]) >> (toI32(a[1]) & 31));
				case 0x65: return num(uint(toI32(a[0])) >>> (toI32(a[1]) & 31));
				case 0x32: var s:String = toStr(a[0]); return num(s.length ? s.charCodeAt(0) : 0);
				case 0x33: return { t: "str", x: String.fromCharCode(toI32(a[0]) & 0xff) };
				case 0x44:
					var tn:Object = { num: "number", str: "string", bool: "boolean", "null": "null", undef: "undefined" };
					return { t: "str", x: tn[a[0].t] };
			}
			throw new Bail("pure op " + code);
		}

		public static function valKey(v:Object):String
		{
			return v ? v.t + ":" + escape(String(v.x)) : "?";
		}

		// ================================================================= output

		public static function peephole(items:Array):Array
		{
			var out:Array = [];
			for (var i:int = 0; i < items.length; i++)
			{
				var it:Object = items[i];
				if (it.k == "jump")
				{
					var skip:Boolean = false;
					for (var j:int = i + 1; j < items.length && items[j].k == "label"; j++)
						if (items[j].id == it.id) { skip = true; break; }
					if (skip) continue;
				}
				out.push(it);
			}
			return out;
		}

		private static function countStrings(items:Array, cnt:Object):void
		{
			for each (var it:Object in items)
			{
				if (it.k == "push")
				{
					for each (var v:Object in it.v) if (v.t == "str") cnt["$" + v.x] = int(cnt["$" + v.x]) + 1;
				}
				else if (it.k == "func") countStrings(it.items, cnt);
			}
		}

		private static function assemble(items:Array):ByteArray
		{
			var cnt:Object = {};
			countStrings(items, cnt);
			var names:Array = [];
			for (var k:String in cnt)
			{
				var s:String = k.substr(1);
				if (cnt[k] > 1 || s.length > 2) names.push({ s: s, w: cnt[k] * (s.length + 1) });
			}
			names.sortOn("w", Array.NUMERIC | Array.DESCENDING);
			var pool:Object = {};
			var list:Array = [];
			var size:int = 2;
			for each (var n:Object in names)
			{
				if (size + n.s.length + 1 > 65000 || list.length >= 65000) break;
				pool["$" + n.s] = list.length;
				list.push(n.s);
				size += n.s.length + 1;
			}
			var out:ByteArray = new ByteArray();
			out.endian = Endian.LITTLE_ENDIAN;
			if (list.length)
			{
				var pd:ByteArray = new ByteArray();
				pd.endian = Endian.LITTLE_ENDIAN;
				pd.writeShort(list.length);
				for each (var ps:String in list) { writeStr(pd, ps); pd.writeByte(0); }
				out.writeByte(0x88);
				out.writeShort(pd.length);
				out.writeBytes(pd);
			}
			out.writeBytes(bodyBytes(items, pool));
			return out;
		}

		private static function writeStr(out:ByteArray, s:String):void
		{
			for (var i:int = 0; i < s.length; i++) out.writeByte(s.charCodeAt(i));
		}

		private static function encVal(out:ByteArray, v:Object, pool:Object):void
		{
			switch (v.t)
			{
				case "str":
					var k:* = pool["$" + v.x];
					if (k !== undefined)
					{
						if (k < 256) { out.writeByte(8); out.writeByte(k); }
						else { out.writeByte(9); out.writeShort(k); }
					}
					else { out.writeByte(0); writeStr(out, v.x); out.writeByte(0); }
					return;
				case "num":
					var x:Number = v.x;
					if (x == int(x) && !(x == 0 && 1 / x < 0) && x >= -2147483648 && x <= 2147483647)
					{
						out.writeByte(7); out.writeInt(int(x));
					}
					else
					{
						var t:ByteArray = new ByteArray();
						t.endian = Endian.LITTLE_ENDIAN;
						t.writeDouble(x);
						out.writeByte(6);
						out.writeBytes(t, 4, 4);
						out.writeBytes(t, 0, 4);
					}
					return;
				case "bool": out.writeByte(5); out.writeByte(v.x ? 1 : 0); return;
				case "null": out.writeByte(2); return;
				case "undef": out.writeByte(3); return;
				case "reg": out.writeByte(4); out.writeByte(v.x); return;
			}
			throw new Bail("can't write " + v.t);
		}

		private static function bodyBytes(items:Array, pool:Object):ByteArray
		{
			// encode everything but the branches, then place labels
			var enc:Array = [];
			for each (var it:Object in items)
			{
				var r:ByteArray;
				if (it.k == "push")
				{
					var d:ByteArray = new ByteArray();
					d.endian = Endian.LITTLE_ENDIAN;
					for each (var v:Object in it.v) encVal(d, v, pool);
					r = new ByteArray(); r.endian = Endian.LITTLE_ENDIAN;
					r.writeByte(0x96); r.writeShort(d.length); r.writeBytes(d);
					enc.push({ k: "raw", r: r });
				}
				else if (it.k == "op")
				{
					r = new ByteArray(); r.endian = Endian.LITTLE_ENDIAN;
					r.writeByte(it.c);
					if (it.c >= 0x80)
					{
						var od:ByteArray = it.d;
						r.writeShort(od ? od.length : 0);
						if (od && od.length) r.writeBytes(od);
					}
					enc.push({ k: "raw", r: r });
				}
				else if (it.k == "func")
				{
					var code:ByteArray = bodyBytes(it.items, pool);
					var hdr:ByteArray = it.hdr;
					r = new ByteArray(); r.endian = Endian.LITTLE_ENDIAN;
					r.writeByte(it.c);
					r.writeShort(hdr.length + 2);
					r.writeBytes(hdr);
					r.writeShort(code.length);
					r.writeBytes(code);
					enc.push({ k: "raw", r: r });
				}
				else enc.push(it);
			}
			var pos:Object = {};
			var at:int = 0;
			for each (var e:Object in enc)
			{
				if (e.k == "label") pos[e.id] = at;
				else if (e.k == "raw") at += e.r.length;
				else at += 5;
			}
			var out:ByteArray = new ByteArray();
			out.endian = Endian.LITTLE_ENDIAN;
			for each (e in enc)
			{
				if (e.k == "label") continue;
				if (e.k == "raw") { out.writeBytes(e.r); continue; }
				var off:int = pos[e.id] - (out.length + 5);
				if (off < -32768 || off > 32767) throw new Bail("branch too far");
				out.writeByte(e.k == "jump" ? 0x99 : 0x9d);
				out.writeShort(2);
				out.writeShort(off);
			}
			return out;
		}

		public static function getPure(code:int):int { return PURE[code] !== undefined ? PURE[code] : -1; }
		public static function getFixed(code:int):Array { return FIXED[code] as Array; }
		public static function get undef():Object { return UNDEF; }
	}
}

import flash.utils.ByteArray;
import fp.avm1.Deobfuscator;

class Bail extends Error
{
	public function Bail(m:String) { super(m); }
}

class Op
{
	public var pc:int;
	public var code:int;
	public var len:int;
	public var data:int;
	public var end:int;
}

/** a stack slot: a known value (val) or a runtime one (val null); mat = already in the written code */
class Entry
{
	public var val:Object;
	public var mat:Boolean;
	public var many:Boolean; // below an Enumerate: any number of runtime values
	public function Entry(val:Object, mat:Boolean, many:Boolean = false) { this.val = val; this.mat = mat; this.many = many; }
	public function copy():Entry { return many ? this : new Entry(val, mat); }
}

/** one code region: a block, or a function body */
class Unit
{
	private var d:Deobfuscator;
	private var start:int;
	private var pool0:Array;
	private var depth:int;
	private var out:Array;
	private var labels:Object;
	private var nlabel:int;
	private var work:Array;
	private var steps:int;
	private var funcs:Object;
	private var end:int = -1;
	private var joins:Object = {};
	private var njoins:int = 0;
	private static const MANY:Entry = new Entry(null, true, true);

	public function Unit(d:Deobfuscator, start:int, pool:Array, depth:int)
	{
		this.d = d; this.start = start; this.pool0 = pool; this.depth = depth;
	}

	public function run(end:int):Array
	{
		this.end = end;
		if (depth > 20) throw new Bail("functions nested too deep");
		// walk until the set of join points is complete (a join found late would duplicate code)
		for (var pass:int = 0; pass < 6; pass++)
		{
			var before:int = njoins;
			out = []; labels = {}; nlabel = 0; work = []; funcs = {}; steps = 0;
			path(start, {}, [], pool0, true, false);
			while (work.length)
			{
				var w:Object = work.pop();
				out.push({ k: "label", id: w.lab });
				path(w.pc, w.vars, w.st, w.pool, false, true);
			}
			if (njoins == before) break;
		}
		return out;
	}

	private function emit(c:int, data:ByteArray = null):void { out.push({ k: "op", c: c, d: data }); }

	private function materialize(st:Array):void
	{
		var run:Array = [];
		for each (var e:Entry in st) if (!e.many && !e.mat) run.push(e);
		if (!run.length) return;
		var vals:Array = [];
		for each (e in run) { vals.push(e.val); e.mat = true; }
		out.push({ k: "push", v: vals });
	}

	private function key(pc:int, vars:Object, st:Array):String
	{
		var names:Array = [];
		for (var n:String in vars) names.push(n);
		names.sort();
		var s:String = pc + "|";
		for each (n in names) s += escape(n) + "=" + Deobfuscator.valKey(vars[n]) + ",";
		s += "|";
		for each (var e:Entry in st)
			s += (e.many ? "M" : (e.mat && !e.val ? "m" : (e.mat ? "1" : "0") + Deobfuscator.valKey(e.val))) + ";";
		return s;
	}

	private function gotoOrLabel(pc:int, vars:Object, st:Array):Array
	{
		var k:String = key(pc, vars, st);
		if (labels[k] !== undefined) return [labels[k], false];
		var lab:int = nlabel++;
		labels[k] = lab;
		return [lab, true];
	}

	private static function copyVars(v:Object):Object { var r:Object = {}; for (var k:String in v) r[k] = v[k]; return r; }
	private static function copyStack(st:Array):Array { var r:Array = []; for each (var e:Entry in st) r.push(e.copy()); return r; }

	private function isKnownStr(e:Entry):Boolean { return !e.many && !e.mat && e.val && e.val.t == "str"; }
	private function isKnown(e:Entry):Boolean { return !e.many && !e.mat && e.val != null; }

	private function path(pc:int, vars:Object, st:Array, pool:Array, branch:Boolean, labDone:Boolean):void
	{
		vars = copyVars(vars);
		st = copyStack(st);
		var first:Boolean = true;
		while (true)
		{
			if (++steps > 400000) throw new Bail("code too long");
			if ((branch || joins[pc]) && !(first && labDone))
			{
				var gl:Array = gotoOrLabel(pc, vars, st);
				if (!gl[1]) { out.push({ k: "jump", id: gl[0] }); return; }
				out.push({ k: "label", id: gl[0] });
			}
			first = false;
			branch = false;
			if (pc == end) { emit(0); return; }
			var op:* = d.opAt(pc);
			var c:int = op.code;
			var nxt:int = op.end;
			var e:Entry, n:int, fx:Array;
			if (c == 0x00) { emit(0); return; }
			if (c == 0x3e) { need(st, 1); materialize(st); emit(0x3e); return; }
			if (c == 0x88) { pool = d.parsePool(op); pc = nxt; continue; }
			if (c == 0x96)
			{
				for each (var v:Object in d.pushValues(op, pool))
				{
					if (v.t == "reg")
					{
						materialize(st);
						out.push({ k: "push", v: [v] });
						st.push(new Entry(null, true));
					}
					else st.push(new Entry(v, false));
				}
				pc = nxt; continue;
			}
			if (c == 0x99) { pc = Deobfuscator.target(op, d); branch = true; continue; }
			if (c == 0x9d)
			{
				var cond:Entry = pop(st);
				if (cond.val != null)
				{
					if (cond.mat) emit(0x17); // a known value already written out: drop it at runtime
					if (Deobfuscator.toBool(cond.val)) { pc = Deobfuscator.target(op, d); branch = true; }
					else pc = nxt;
					continue;
				}
				var tgt:int = Deobfuscator.target(op, d);
				if (!joins[tgt]) { joins[tgt] = true; njoins++; }
				var g2:Array = gotoOrLabel(tgt, vars, st);
				out.push({ k: "if", id: g2[0] });
				if (g2[1]) work.push({ lab: g2[0], pc: tgt, vars: copyVars(vars), st: copyStack(st), pool: pool });
				pc = nxt; branch = true; continue;
			}
			n = Deobfuscator.getPure(c);
			if (n >= 0)
			{
				need(st, n);
				var args:Array = st.slice(st.length - n);
				var allKnown:Boolean = true;
				for each (e in args) if (!isKnown(e)) allKnown = false;
				if (allKnown)
				{
					var vals:Array = [];
					for each (e in args) vals.push(e.val);
					var res:Object = null;
					try { res = Deobfuscator.pureOp(c, vals); } catch (pe:Bail) { res = null; }
					if (res)
					{
						st.length -= n;
						st.push(new Entry(res, false));
						pc = nxt; continue;
					}
				}
				real(st, c, op, n, 1); pc = nxt; continue;
			}
			if (c == 0x17)
			{
				e = pop(st);
				if (e.mat) emit(0x17);
				pc = nxt; continue;
			}
			if (c == 0x4c)
			{
				need(st, 1);
				e = st[st.length - 1];
				if (isKnown(e)) st.push(new Entry(e.val, false));
				else { materialize(st); emit(0x4c); st.push(new Entry(e.many ? null : e.val, true)); }
				pc = nxt; continue;
			}
			if (c == 0x4d)
			{
				need(st, 2);
				var a:Entry = st[st.length - 2], bb:Entry = st[st.length - 1];
				if (!a.many && !bb.many && !a.mat && !bb.mat) { st[st.length - 2] = bb; st[st.length - 1] = a; }
				else
				{
					materialize(st); emit(0x4d);
					if (!a.many && !bb.many) { st[st.length - 2] = bb; st[st.length - 1] = a; }
				}
				pc = nxt; continue;
			}
			if (c == 0x1c)
			{
				need(st, 1);
				e = st[st.length - 1];
				if (isKnownStr(e) && Deobfuscator.isObfName(e.val.x))
				{
					st.pop();
					var known:Object = vars[e.val.x];
					st.push(new Entry(known ? known : Deobfuscator.undef, false));
					pc = nxt; continue;
				}
				real(st, c, op, 1, 1); pc = nxt; continue;
			}
			if (c == 0x1d || c == 0x3c)
			{
				need(st, 2);
				var nm:Entry = st[st.length - 2], val:Entry = st[st.length - 1];
				if (isKnownStr(nm) && Deobfuscator.isObfName(nm.val.x) && isKnown(val))
				{
					vars[nm.val.x] = val.val;
					st.length -= 2;
					pc = nxt; continue;
				}
				real(st, c, op, 2, 0); pc = nxt; continue;
			}
			if (c == 0x9b || c == 0x8e)
			{
				var fi:Array = d.funcInfo(op);
				var body:int = nxt;
				var bend:int = body + int(fi[1]);
				if (Deobfuscator.isObfName(fi[0]))
				{
					funcs["$" + fi[0]] = { start: body, end: bend, pool: pool };
					pc = bend; continue;
				}
				var sub:Unit = new Unit(d, body, pool, depth + 1);
				var subItems:Array = Deobfuscator.peephole(sub.run(bend));
				materialize(st);
				out.push({ k: "func", c: c, hdr: d.bytes(op.data, op.len - 2), items: subItems });
				if (fi[0] == "") st.push(new Entry(null, true));
				pc = bend; continue;
			}
			if (c == 0x3d)
			{
				need(st, 2);
				var fnm:Entry = st[st.length - 1], cnt:Entry = st[st.length - 2];
				if (isKnownStr(fnm) && funcs["$" + fnm.val.x] && isKnown(cnt))
				{
					n = Deobfuscator.toI32(cnt.val);
					need(st, 2 + n);
					var ok:Boolean = true;
					for (var ai:int = st.length - 2 - n; ai < st.length - 2; ai++) if (!isKnown(st[ai])) ok = false;
					if (ok)
					{
						var r:Object = inline(funcs["$" + fnm.val.x], vars);
						st.length -= 2 + n;
						st.push(new Entry(r, false));
						pc = nxt; continue;
					}
				}
				n = countAt(st, 2);
				real(st, c, op, 2 + n, 1); pc = nxt; continue;
			}
			if (c == 0x52 || c == 0x53) { n = countAt(st, 3); real(st, c, op, 3 + n, 1); pc = nxt; continue; }
			if (c == 0x40) { n = countAt(st, 2); real(st, c, op, 2 + n, 1); pc = nxt; continue; }
			if (c == 0x42) { n = countAt(st, 1); real(st, c, op, 1 + n, 1); pc = nxt; continue; }
			if (c == 0x43) { n = countAt(st, 1); real(st, c, op, 1 + 2 * n, 1); pc = nxt; continue; }
			if (c == 0x2c) { n = countAt(st, 2); real(st, c, op, 2 + n, 0); pc = nxt; continue; }
			if (c == 0x27)
			{
				need(st, 3);
				e = st[st.length - 3];
				if (e.many || e.val == null) throw new Bail("startDrag constraint unknown");
				real(st, c, op, Deobfuscator.toBool(e.val) ? 7 : 3, 0); pc = nxt; continue;
			}
			if (c == 0x46 || c == 0x55) { real(st, c, op, 1, 0); st.push(MANY); pc = nxt; continue; }
			if (c == 0x87) { need(st, 1); materialize(st); emit(c, d.bytes(op.data, op.len)); pc = nxt; continue; }
			if (c == 0x8f) throw new Bail("try block");
			if (c == 0x94) throw new Bail("with block");
			if (c == 0x8a || c == 0x8d) throw new Bail("waitForFrame");
			fx = Deobfuscator.getFixed(c);
			if (fx) { real(st, c, op, fx[0], fx[1]); pc = nxt; continue; }
			throw new Bail("unknown action " + c.toString(16) + " at " + pc);
		}
	}

	/** run an obfuscator helper ("\x04\x05": set "\x03", return it) on known values */
	private function inline(fn:Object, vars:Object):Object
	{
		var st:Array = [];
		var pc:int = fn.start;
		for (var i:int = 0; i < 10000; i++)
		{
			if (pc == fn.end) return Deobfuscator.undef;
			var op:* = d.opAt(pc);
			var c:int = op.code;
			var nxt:int = op.end;
			var n:int = Deobfuscator.getPure(c);
			if (c == 0x96)
			{
				for each (var v:Object in d.pushValues(op, fn.pool))
				{
					if (v.t == "reg") throw new Bail("helper uses registers");
					st.push(v);
				}
			}
			else if (n >= 0)
			{
				if (st.length < n) throw new Bail("helper stack");
				var r:Object = Deobfuscator.pureOp(c, st.slice(st.length - n));
				st.length -= n;
				st.push(r);
			}
			else if (c == 0x1c)
			{
				var nm:Object = st.pop();
				if (!nm || nm.t != "str" || !Deobfuscator.isObfName(nm.x)) throw new Bail("helper reads a real variable");
				st.push(vars[nm.x] ? vars[nm.x] : Deobfuscator.undef);
			}
			else if (c == 0x1d || c == 0x3c)
			{
				var val:Object = st.pop();
				var nm2:Object = st.pop();
				if (!nm2 || nm2.t != "str" || !Deobfuscator.isObfName(nm2.x)) throw new Bail("helper sets a real variable");
				vars[nm2.x] = val;
			}
			else if (c == 0x3e) return st.length ? st.pop() : Deobfuscator.undef;
			else if (c == 0x99) nxt = Deobfuscator.target(op, d);
			else if (c == 0x9d) { if (Deobfuscator.toBool(st.pop())) nxt = Deobfuscator.target(op, d); }
			else if (c == 0x17) st.pop();
			else if (c == 0x00) return Deobfuscator.undef;
			else throw new Bail("helper action " + c.toString(16));
			pc = nxt;
		}
		throw new Bail("helper loops");
	}

	// ---- stack helpers
	private function need(st:Array, n:int):void
	{
		var have:int = 0;
		for (var i:int = st.length - 1; i >= 0; i--)
		{
			if (st[i].many) return;
			if (++have >= n) return;
		}
		// stack underflow in the original: Flash gives undefined
		while (have++ < n) st.unshift(new Entry(Deobfuscator.undef, false));
	}

	private function pop(st:Array):Entry
	{
		need(st, 1);
		var e:Entry = st.pop();
		if (e.many) { st.push(e); return new Entry(null, true); }
		return e;
	}

	private function countAt(st:Array, depth:int):int
	{
		need(st, depth);
		var i:int = st.length - depth;
		var e:Entry = i >= 0 ? st[i] : MANY;
		if (e.many || e.val == null) throw new Bail("call with an argument count known only at runtime");
		var n:int = Deobfuscator.toI32(e.val);
		if (n < 0 || n > 255) throw new Bail("argument count " + n);
		return n;
	}

	private function real(st:Array, c:int, op:*, pops:int, pushes:int):void
	{
		need(st, pops);
		materialize(st);
		emit(c, c >= 0x80 ? d.bytes(op.data, op.len) : null);
		for (var i:int = 0; i < pops; i++)
		{
			var e:Entry = st.pop();
			if (e.many) { st.push(e); break; }
		}
		for (i = 0; i < pushes; i++) st.push(new Entry(null, true));
	}
}
