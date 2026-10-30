package fp
{
	import flash.utils.ByteArray;
	import flash.utils.Endian;

	/**
	 * Save games for AS3 files played in AIR: the game's references to flash.net.SharedObject and
	 * flash.external.ExternalInterface are pointed at bwekh.SharedObject / bwekh.ExternalInterface
	 * (source: tools/so-shim), whose code is added to the SWF here. They keep each game's saves
	 * (and browser-cookie saves) in its own folder, and the player writes them out on close.
	 */
	public class SoPatch
	{
		public static const CLASS_NAME:String = "bwekh.SharedObject";
		/** (tests, tools/airtest) DoABC flags of the added code: 1 = lazy, 0 = run at once */
		public static var shimFlags:int = 1;
		/** (tests) add the code even when nothing in the game is changed */
		public static var forceShims:Boolean = false;
		/** (tests) the new base class is flash.display.MovieClip itself: checks the patching alone */
		public static var testBuiltinBase:Boolean = false;
		/** (tests) use this existing multiname as the new base (no new one, same operand size) */
		public static var testReuseMn:int = 0;
		/** (tests, with testReuseMn) add no string / namespace: the ABC is only rebuilt */
		public static var testNoAdd:Boolean = false;

		/** returns the patched SWF (uncompressed), or null when the game doesn't use SharedObject */
		/**
		 * baseFix 3: the main class's constructor reads bwekh.appStage (the player's stage) where
		 * it reads "stage": a browser has the stage there, a game the player loads doesn't (#1009,
		 * Inter Schminter comics). Only as a second try for a game that failed so.
		 * (1 / 2, main class on bwekh.SpritePlain / SpriteBase: AIR rejects any change of a main
		 * class's base class with #1107, kept for tools/airtest only.)
		 */
		public static function patch(swf:ByteArray, baseFix:int = 0):ByteArray
		{
			var body:ByteArray = SwfBytes.decompress(swf);
			if (!body) return null;
			swf.position = 0;
			var version:int = swf[3];
			// RECT + frame rate + frame count
			var nbits:int = body[0] >> 3;
			var p:int = int((5 + 4 * nbits + 7) / 8) + 4;
			var out:ByteArray = new ByteArray();
			out.endian = Endian.LITTLE_ENDIAN;
			out.writeBytes(body, 0, p);
			var changed:Boolean = false;
			var shimAdded:Boolean = false;
			body.endian = Endian.LITTLE_ENDIAN;
			var doc:String = docClass(body, p);
			while (p + 2 <= body.length)
			{
				body.position = p;
				var h:int = body.readUnsignedShort();
				var code:int = h >> 6;
				var len:int = h & 63;
				if (len == 63) len = body.readUnsignedInt();
				var start:int = body.position;
				if (start + len > body.length) len = body.length - start;
				var done:Boolean = false;
				if (code == 82 || code == 72)
				{
					var abcStart:int = start;
					var head:ByteArray = new ByteArray();
					if (code == 82)
					{
						abcStart = start + 4;
						while (abcStart < start + len && body[abcStart] != 0) abcStart++;
						abcStart++;
						head.writeBytes(body, start, abcStart - start);
					}
					var abc:ByteArray = new ByteArray();
					abc.writeBytes(body, abcStart, start + len - abcStart);
					var patched:ByteArray = null;
					try { patched = patchAbc(abc, baseFix ? doc : null, baseFix == 3 ? "ctor" : baseFix == 1 ? "Plain" : "Base"); } catch (e:Error) { patched = null; }
					if (!shimAdded)
					{
						for each (var shim:ByteArray in shimAbcs())
						{
							var sh:ByteArray = new ByteArray();
							sh.endian = Endian.LITTLE_ENDIAN;
							sh.writeUnsignedInt(shimFlags);
							sh.writeUTFBytes("bwekh");
							sh.writeByte(0);
							sh.writeBytes(shim);
							writeTag(out, 82, sh);
						}
						shimAdded = true;
					}
					if (patched)
					{
						changed = true;
						var nb:ByteArray = new ByteArray();
						nb.writeBytes(head);
						nb.writeBytes(patched);
						writeTag(out, code, nb);
						done = true;
					}
				}
				if (!done) out.writeBytes(body, p, start + len - p);
				p = start + len;
				if (code == 0) break;
			}
			if (!changed && !forceShims) return null;
			var res:ByteArray = new ByteArray();
			res.endian = Endian.LITTLE_ENDIAN;
			res.writeUTFBytes("FWS");
			res.writeByte(version);
			res.writeUnsignedInt(out.length + 8);
			res.writeBytes(out);
			res.position = 0;
			return res;
		}

		private static function writeTag(out:ByteArray, code:int, data:ByteArray):void
		{
			out.writeShort((code << 6) | 63);
			out.writeUnsignedInt(data.length);
			out.writeBytes(data);
		}

		// ------------------------------------------------------------------ ABC

		private static function u30(b:ByteArray):uint
		{
			var r:uint = 0;
			for (var i:int = 0; i < 5; i++)
			{
				var c:uint = b.readUnsignedByte();
				r |= (c & 0x7F) << (7 * i);
				if (!(c & 0x80)) break;
			}
			return r;
		}

		private static function w30(b:ByteArray, v:uint):void
		{
			do
			{
				var c:uint = v & 0x7F;
				v >>>= 7;
				if (v) c |= 0x80;
				b.writeByte(c);
			}
			while (v);
		}

		/** the SWF's main class ("pkg.Name") from its SymbolClass tag, or null */
		private static function docClass(body:ByteArray, p:int):String
		{
			while (p + 2 <= body.length)
			{
				body.position = p;
				var h:int = body.readUnsignedShort();
				var code:int = h >> 6;
				var len:int = h & 63;
				if (len == 63) len = body.readUnsignedInt();
				var start:int = body.position;
				if (code == 76 && start + 2 <= body.length)
				{
					var n:int = body.readUnsignedShort();
					for (var i:int = 0; i < n && body.position < start + len; i++)
					{
						var id:int = body.readUnsignedShort();
						var q:int = body.position;
						while (q < start + len && body[q] != 0) q++;
						var name:String = body.readUTFBytes(q - body.position);
						body.position = q + 1;
						if (id == 0) return name;
					}
				}
				p = start + len;
				if (code == 0) break;
			}
			return null;
		}

		/** classes replaced: package, name */
		private static const TARGETS:Array = [["flash.net", "SharedObject"], ["flash.external", "ExternalInterface"]];

		/**
		 * The ABC with the TARGETS classes turned into bwekh ones, and with the main class `doc`
		 * ("pkg.Name") put on bwekh.MovieClipBase / SpriteBase (stage in its constructor);
		 * null if nothing changes.
		 */
		public static function patchAbc(abc:ByteArray, doc:String = null, suffix:String = "Base"):ByteArray
		{
			abc.endian = Endian.LITTLE_ENDIAN;
			abc.position = 4;
			var i:int, j:int, t:int, n:int;
			var T:int = TARGETS.length;
			n = u30(abc); for (i = 1; i < n; i++) u30(abc);   // int
			n = u30(abc); for (i = 1; i < n; i++) u30(abc);   // uint
			n = u30(abc); if (n > 1) abc.position += 8 * (n - 1);   // double
			var strStart:int = abc.position;
			var strCount:int = u30(abc);
			var strBodyStart:int = abc.position;
			var strs:Array = [null];
			for (i = 1; i < strCount; i++)
			{
				var sl:int = u30(abc);
				strs.push(abc.readUTFBytes(sl));
			}
			var strBodyEnd:int = abc.position;
			var bwekhStr:int = strs.indexOf("bwekh");
			// namespaces
			var nsCount:int = u30(abc);
			var nsKind:Array = [0], nsName:Array = [0];
			for (i = 1; i < nsCount; i++)
			{
				nsKind.push(abc.readUnsignedByte());
				nsName.push(u30(abc));
			}
			// namespace sets
			var setCount:int = u30(abc);
			var sets:Array = [null];
			for (i = 1; i < setCount; i++)
			{
				var c:int = u30(abc);
				var arr:Array = [];
				for (j = 0; j < c; j++) arr.push(u30(abc));
				sets.push(arr);
			}
			// multinames
			var mnCount:int = u30(abc);
			var mns:Array = [null];
			var hits:int = 0;
			for (i = 1; i < mnCount; i++)
			{
				var m:Object = { k: abc.readUnsignedByte() };
				switch (m.k)
				{
					case 0x07: case 0x0D: m.ns = u30(abc); m.name = u30(abc);
						for (t = 0; t < T; t++)
							if (nsKind[m.ns] == 0x16 && strs[nsName[m.ns]] == TARGETS[t][0] && strs[m.name] == TARGETS[t][1]) { m.fix = true; hits++; }
						break;
					case 0x0F: case 0x10: m.name = u30(abc); break;
					case 0x11: case 0x12: break;
					case 0x09: case 0x0E: m.name = u30(abc); m.set = u30(abc);
						for (t = 0; t < T; t++)
						{
							if (strs[m.name] != TARGETS[t][1]) continue;
							for each (var sn0:int in sets[m.set])
								if (nsKind[sn0] == 0x16 && strs[nsName[sn0]] == TARGETS[t][0]) { m.fix = true; hits++; break; }
						}
						break;
					case 0x1B: case 0x1C: m.set = u30(abc); break;
					case 0x1D: m.qn = u30(abc); var pc:int = u30(abc); m.params = [];
						for (j = 0; j < pc; j++) m.params.push(u30(abc));
						break;
					default: return null;   // unknown: leave this ABC alone
				}
				mns.push(m);
			}
			var restStart:int = abc.position;

			// the main class: where its super class index is written, and the "getlex <super>" in
			// front of its "newclass" (both must name the new base class)
			var edits:Array = null, baseName:String = null, superIdx:int = -1;
			if (doc && suffix == "ctor")
			{
				// the main class's constructor: its "getlex stage" read bwekh.appStage instead
				try
				{
					var dot0:int = doc.lastIndexOf(".");
					var cf:Object = findCtorStage(abc, restStart, mns, strs, nsName,
						dot0 >= 0 ? doc.substr(0, dot0) : "", dot0 >= 0 ? doc.substr(dot0 + 1) : doc);
					var newLen:ByteArray = new ByteArray();
					w30(newLen, Math.max(1, mnCount));
					if (cf && cf.edits.length)
					{
						edits = [];
						// (only operands of the same size: nothing else in the code moves)
						for each (var ce:Object in cf.edits) if (ce.len == newLen.length) edits.push(ce);
						if (!edits.length) edits = null;
					}
					if (edits) baseName = "appStage";
				}
				catch (ce0:Error) { edits = null; }
			}
			else if (doc)
			{
				try
				{
					var dot:int = doc.lastIndexOf(".");
					var found:Object = findSuper(abc, restStart, mns, strs, nsName,
						dot >= 0 ? doc.substr(0, dot) : "", dot >= 0 ? doc.substr(dot + 1) : doc);
					var sm:Object = found ? mns[found.idx] : null;
					if (sm && (sm.k == 0x07 || sm.k == 0x0D) && strs[nsName[sm.ns]] == "flash.display" &&
						(strs[sm.name] == "MovieClip" || strs[sm.name] == "Sprite"))
					{
						edits = found.edits;
						superIdx = found.idx;
						baseName = testBuiltinBase ? "MovieClip" : strs[sm.name] + suffix;
					}
				}
				catch (de:Error) { edits = null; }
			}
			var superAt:int = edits ? 1 : -1;
			if (!hits && superAt < 0) return null;

			var out:ByteArray = new ByteArray();
			out.endian = Endian.LITTLE_ENDIAN;
			out.writeBytes(abc, 0, strStart);
			// strings (+ "bwekh", + base class name)
			var added:Array = [];
			var next:int = Math.max(1, strCount);
			if (bwekhStr < 0 && !testNoAdd) { bwekhStr = next++; added.push("bwekh"); }
			var baseStr:int = -1;
			if (superAt >= 0 && !testNoAdd)
			{
				baseStr = strs.indexOf(baseName);
				if (baseStr < 0) { baseStr = next++; added.push(baseName); }
			}
			w30(out, next);
			if (strBodyEnd > strBodyStart) out.writeBytes(abc, strBodyStart, strBodyEnd - strBodyStart);
			for each (var as0:String in added)
			{
				var sb:ByteArray = new ByteArray();
				sb.writeUTFBytes(as0);
				w30(out, sb.length);
				out.writeBytes(sb);
			}
			// namespaces (+ package bwekh)
			var newNs:int = Math.max(1, nsCount);
			w30(out, testNoAdd ? nsCount : newNs + 1);
			for (i = 1; i < nsCount; i++) { out.writeByte(nsKind[i]); w30(out, nsName[i]); }
			if (!testNoAdd) { out.writeByte(0x16); w30(out, bwekhStr); }
			// sets
			w30(out, setCount);
			for (i = 1; i < setCount; i++)
			{
				w30(out, sets[i].length);
				for each (var sn:int in sets[i]) w30(out, sn);
			}
			// multinames (+ bwekh::<base>)
			var baseMn:int = Math.max(1, mnCount);
			w30(out, superAt >= 0 && testReuseMn <= 0 ? baseMn + 1 : mnCount);
			for (i = 1; i < mnCount; i++)
			{
				m = mns[i];
				if (m.fix)
				{
					out.writeByte(m.k == 0x0D || m.k == 0x0E ? 0x0D : 0x07);
					w30(out, newNs); w30(out, m.name);
					continue;
				}
				out.writeByte(m.k);
				switch (m.k)
				{
					case 0x07: case 0x0D: w30(out, m.ns); w30(out, m.name); break;
					case 0x0F: case 0x10: w30(out, m.name); break;
					case 0x09: case 0x0E: w30(out, m.name); w30(out, m.set); break;
					case 0x1B: case 0x1C: w30(out, m.set); break;
					case 0x1D: w30(out, m.qn); w30(out, m.params.length);
						for each (var pp:int in m.params) w30(out, pp);
						break;
				}
			}
			if (superAt >= 0 && testReuseMn <= 0) { out.writeByte(0x07); w30(out, testBuiltinBase ? mns[superIdx].ns : newNs); w30(out, baseStr); }
			if (testReuseMn > 0) baseMn = testReuseMn;
			if (edits)
			{
				// edits: [{at, len, value}] sorted by position; value "base" = the new multiname,
				// "len+" = a code_length field to grow by the size change of the getlex operand
				var tmp:ByteArray = new ByteArray();
				w30(tmp, baseMn);
				var grow:int = tmp.length - edits[0].len;   // super_name and getlex operand are the same index
				var pos:int = restStart;
				for each (var ed:Object in edits)
				{
					out.writeBytes(abc, pos, ed.at - pos);
					if (ed.value == "base") w30(out, baseMn);
					else w30(out, ed.old + grow);
					pos = ed.at + ed.len;
				}
				out.writeBytes(abc, pos, abc.length - pos);
			}
			else out.writeBytes(abc, restStart, abc.length - restStart);
			return out;
		}

		/**
		 * {idx, edits}: the super class multiname of class pkg.name, and the places to change for a
		 * new base class: its super_name, the code_length of the script that creates it and the
		 * getlex operand right before its newclass. Null when it can't be done safely (branches or
		 * unknown opcodes in that script).
		 */
		private static function findSuper(abc:ByteArray, p:int, mns:Array, strs:Array, nsName:Array,
			pkg:String, name:String):Object
		{
			abc.position = p;
			var i:int, j:int, n:int;
			// method_info
			var mc:int = u30(abc);
			for (i = 0; i < mc; i++)
			{
				var pcount:int = u30(abc);
				u30(abc);                                   // return type
				for (j = 0; j < pcount; j++) u30(abc);      // param types
				u30(abc);                                   // name
				var flags:int = abc.readUnsignedByte();
				if (flags & 0x08)
				{
					n = u30(abc);
					for (j = 0; j < n; j++) { u30(abc); abc.readUnsignedByte(); }
				}
				if (flags & 0x80) for (j = 0; j < pcount; j++) u30(abc);
			}
			// metadata
			var md:int = u30(abc);
			for (i = 0; i < md; i++)
			{
				u30(abc);
				n = u30(abc);
				for (j = 0; j < n * 2; j++) u30(abc);
			}
			// instance_info
			var cc:int = u30(abc);
			var cls:int = -1, sup:int = -1, supAt:int = -1, supLen:int = 0;
			for (i = 0; i < cc; i++)
			{
				var nm:int = u30(abc);
				var at:int = abc.position;
				var s0:int = u30(abc);
				var m:Object = mns[nm];
				if (cls < 0 && m && (m.k == 0x07 || m.k == 0x0D) && strs[m.name] == name && strs[nsName[m.ns]] == pkg)
				{
					cls = i; sup = s0; supAt = at; supLen = abc.position - at;
				}
				var f:int = abc.readUnsignedByte();
				if (f & 0x08) u30(abc);                     // protected namespace
				n = u30(abc);
				for (j = 0; j < n; j++) u30(abc);           // interfaces
				u30(abc);                                   // iinit
				skipTraits(abc);
			}
			if (cls < 0) return null;
			for (i = 0; i < cc; i++) { u30(abc); skipTraits(abc); }       // class_info
			var sc:int = u30(abc);
			for (i = 0; i < sc; i++) { u30(abc); skipTraits(abc); }       // script_info
			// method bodies: the one with "newclass cls"
			var bc:int = u30(abc);
			for (i = 0; i < bc; i++)
			{
				u30(abc); u30(abc); u30(abc); u30(abc); u30(abc);
				var lenAt:int = abc.position;
				var codeLen:int = u30(abc);
				var lenLen:int = abc.position - lenAt;
				var code:int = abc.position;
				var hit:Object = scanForNewclass(abc, code, code + codeLen, cls, sup);
				abc.position = code + codeLen;
				var exc:int = u30(abc);
				for (j = 0; j < exc * 5; j++) u30(abc);
				skipTraits(abc);
				if (hit === false) return null;             // has it, but can't be changed safely
				if (hit && exc == 0)
					return { idx: sup, edits: [
						{ at: supAt, len: supLen, value: "base" },
						{ at: lenAt, len: lenLen, value: "len", old: codeLen },
						{ at: hit.at, len: hit.len, value: "base" }] };
				if (hit) return null;
			}
			return null;
		}

		/**
		 * {edits}: the operands of the "getlex stage" in the constructor of class pkg.name (they
		 * are to name bwekh.appStage). Null when the class or its constructor isn't found, or the
		 * constructor has opcodes this can't step over.
		 */
		private static function findCtorStage(abc:ByteArray, p:int, mns:Array, strs:Array, nsName:Array,
			pkg:String, name:String):Object
		{
			abc.position = p;
			var i:int, j:int, n:int;
			var mc:int = u30(abc);
			for (i = 0; i < mc; i++)
			{
				var pcount:int = u30(abc);
				u30(abc);
				for (j = 0; j < pcount; j++) u30(abc);
				u30(abc);
				var flags:int = abc.readUnsignedByte();
				if (flags & 0x08)
				{
					n = u30(abc);
					for (j = 0; j < n; j++) { u30(abc); abc.readUnsignedByte(); }
				}
				if (flags & 0x80) for (j = 0; j < pcount; j++) u30(abc);
			}
			var md:int = u30(abc);
			for (i = 0; i < md; i++)
			{
				u30(abc);
				n = u30(abc);
				for (j = 0; j < n * 2; j++) u30(abc);
			}
			var cc:int = u30(abc);
			var iinit:int = -1;
			for (i = 0; i < cc; i++)
			{
				var nm:int = u30(abc);
				u30(abc);
				var m:Object = mns[nm];
				var f:int = abc.readUnsignedByte();
				if (f & 0x08) u30(abc);
				n = u30(abc);
				for (j = 0; j < n; j++) u30(abc);
				var ii:int = u30(abc);
				if (iinit < 0 && m && (m.k == 0x07 || m.k == 0x0D) && strs[m.name] == name && strs[nsName[m.ns]] == pkg) iinit = ii;
				skipTraits(abc);
			}
			if (iinit < 0) return null;
			for (i = 0; i < cc; i++) { u30(abc); skipTraits(abc); }
			var sc:int = u30(abc);
			for (i = 0; i < sc; i++) { u30(abc); skipTraits(abc); }
			// "stage" names: any multiname spelled "stage"
			var stageMn:Object = {};
			for (i = 1; i < mns.length; i++)
			{
				var sm:Object = mns[i];
				if (sm && (sm.k == 0x07 || sm.k == 0x0D || sm.k == 0x09 || sm.k == 0x0E) && strs[sm.name] == "stage") stageMn[i] = true;
			}
			var bc:int = u30(abc);
			for (i = 0; i < bc; i++)
			{
				var meth:int = u30(abc);
				u30(abc); u30(abc); u30(abc); u30(abc);
				var codeLen:int = u30(abc);
				var code:int = abc.position;
				if (meth == iinit)
				{
					var edits:Array = [];
					abc.position = code;
					while (abc.position < code + codeLen)
					{
						var op:int = abc.readUnsignedByte();
						if (op >= 0x0C && op <= 0x1A) { abc.position += 3; continue; }   // jumps (nothing moves)
						if (op == 0x1B)                                                  // lookupswitch
						{
							abc.position += 3;
							var cases:int = u30(abc);
							abc.position += 3 * (cases + 1);
							continue;
						}
						var kinds:String = OPS[op];
						if (!kinds)
						{
							if (PLAIN.indexOf(op) < 0) return null;
							continue;
						}
						for (var k:int = 0; k < kinds.length; k++)
						{
							if (kinds.charAt(k) == "b") { abc.readUnsignedByte(); continue; }
							var at:int = abc.position;
							var v:int = u30(abc);
							if (k == 0 && op == 0x60 && stageMn[v]) edits.push({ at: at, len: abc.position - at, value: "base" });
						}
					}
					return { edits: edits };
				}
				abc.position = code + codeLen;
				var exc:int = u30(abc);
				for (j = 0; j < exc * 5; j++) u30(abc);
				skipTraits(abc);
			}
			return null;
		}

		/** operand kinds of the AVM2 opcodes a script initializer uses: u = u30, b = byte */
		private static const OPS:Object = {
			0x04: "u", 0x05: "u", 0x06: "u", 0x08: "u", 0x24: "b", 0x25: "u", 0x2C: "u", 0x2D: "u", 0x2E: "u",
			0x2F: "u", 0x31: "u", 0x32: "uu", 0x40: "u", 0x41: "u", 0x42: "u", 0x43: "uu", 0x44: "uu", 0x45: "uu",
			0x46: "uu", 0x49: "u", 0x4A: "uu", 0x4C: "uu", 0x4E: "uu", 0x4F: "uu", 0x53: "u", 0x55: "u", 0x56: "u",
			0x58: "u", 0x59: "u", 0x5A: "u", 0x5D: "u", 0x5E: "u", 0x5F: "u", 0x60: "u", 0x61: "u", 0x62: "u",
			0x63: "u", 0x65: "b", 0x66: "u", 0x68: "u", 0x6A: "u", 0x6C: "u", 0x6D: "u", 0x6E: "u", 0x6F: "u",
			0x80: "u", 0x86: "u", 0x92: "u", 0x94: "u", 0xB2: "u", 0xC2: "u", 0xC3: "u", 0xF0: "u", 0xF1: "u",
			0xEF: "bubu"
		};
		/** opcodes without operands that are fine to step over */
		private static const PLAIN:Array = [0x01, 0x02, 0x03, 0x07, 0x09, 0x1C, 0x1D, 0x1E, 0x1F, 0x20, 0x21, 0x23,
			0x26, 0x27, 0x28, 0x29, 0x2A, 0x2B, 0x30, 0x47, 0x48, 0x57, 0x64, 0x70, 0x71, 0x72, 0x73, 0x74, 0x75,
			0x76, 0x77, 0x78, 0x82, 0x85, 0x87, 0x88, 0x89, 0x90, 0x91, 0x93, 0x95, 0x96, 0x97, 0xA0, 0xA1, 0xA2,
			0xA3, 0xA4, 0xA5, 0xA6, 0xA7, 0xA8, 0xA9, 0xAA, 0xAB, 0xAC, 0xAD, 0xAE, 0xAF, 0xB0, 0xB1, 0xB3, 0xB4,
			0xC0, 0xC1, 0xC4, 0xC5, 0xC6, 0xC7, 0xD0, 0xD1, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7];

		/**
		 * null: no "newclass cls" in this code; {at, len}: the operand of the "getlex sup" right in
		 * front of it; false: it's there but the code has jumps / unknown opcodes (don't touch).
		 */
		private static function scanForNewclass(abc:ByteArray, from:int, end:int, cls:int, sup:int):*
		{
			abc.position = from;
			var lastOp:int = -1, lastAt:int = -1, lastLen:int = 0, lastVal:int = -1;
			var safe:Boolean = true;
			var result:Object = null;
			while (abc.position < end)
			{
				var op:int = abc.readUnsignedByte();
				var kinds:String = OPS[op];
				var opAt:int = abc.position, opVal:int = -1;
				if (kinds)
				{
					for (var k:int = 0; k < kinds.length; k++)
					{
						if (kinds.charAt(k) == "b") abc.readUnsignedByte();
						else { var v:int = u30(abc); if (k == 0) opVal = v; }
					}
				}
				else if (PLAIN.indexOf(op) < 0) safe = false;   // jumps, switches, unknown
				if (!safe && result === null && op != 0x58) { /* keep scanning for newclass */ }
				if (op == 0x58 && opVal == cls)
				{
					if (lastOp == 0x60 && lastVal == sup) result = { at: lastAt, len: lastLen };
					else return false;
				}
				lastOp = op;
				lastAt = opAt;
				lastLen = abc.position - opAt;
				lastVal = opVal;
				if (!safe && !kinds) return result ? false : null;
			}
			if (result && !safe) return false;
			return result;
		}

		private static function skipTraits(abc:ByteArray):void
		{
			var n:int = u30(abc);
			for (var i:int = 0; i < n; i++)
			{
				u30(abc);                                   // name
				var k:int = abc.readUnsignedByte();
				switch (k & 0x0F)
				{
					case 0: case 6:                         // slot, const
						u30(abc); u30(abc);
						if (u30(abc)) abc.readUnsignedByte();
						break;
					case 1: case 2: case 3: case 4: case 5: // method, getter, setter, class, function
						u30(abc); u30(abc);
						break;
					default: throw new Error("trait kind");
				}
				if (k & 0x40)
				{
					var mc:int = u30(abc);
					for (var j:int = 0; j < mc; j++) u30(abc);
				}
			}
		}

		// ------------------------------------------------------------------ shim code

		private static var shimBytes:Array;

		private static function shimAbcs():Array
		{
			if (!shimBytes)
			{
				shimBytes = [];
				for each (var s:String in SHIMS) shimBytes.push(b64(s));
			}
			return shimBytes;
		}

		/**
		 * A small SWF with only the bwekh classes: loaded into a domain of its own, which then is
		 * the parent of the game's domain (so the player can hand bwekh.StageHolder its stage first).
		 */
		public static function shimLibrary():ByteArray
		{
			var out:ByteArray = new ByteArray();
			out.endian = Endian.LITTLE_ENDIAN;
			out.writeByte(0);             // RECT with 0-bit fields
			out.writeShort(24 << 8);      // frame rate 24
			out.writeShort(1);            // 1 frame
			var fa:ByteArray = new ByteArray();
			fa.endian = Endian.LITTLE_ENDIAN;
			fa.writeUnsignedInt(0x08);    // ActionScript 3
			writeTag(out, 69, fa);
			for each (var shim:ByteArray in shimAbcs())
			{
				var sh:ByteArray = new ByteArray();
				sh.endian = Endian.LITTLE_ENDIAN;
				sh.writeUnsignedInt(1);
				sh.writeUTFBytes("bwekh");
				sh.writeByte(0);
				sh.writeBytes(shim);
				writeTag(out, 82, sh);
			}
			out.writeShort(1 << 6);       // ShowFrame
			out.writeShort(0);            // End
			var res:ByteArray = new ByteArray();
			res.endian = Endian.LITTLE_ENDIAN;
			res.writeUTFBytes("FWS");
			res.writeByte(10);
			res.writeUnsignedInt(out.length + 8);
			res.writeBytes(out);
			res.position = 0;
			return res;
		}

		private static function b64(s:String):ByteArray
		{
			const T:String = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
			var out:ByteArray = new ByteArray();
			var buf:uint = 0, bits:int = 0;
			for (var i:int = 0; i < s.length; i++)
			{
				var v:int = T.indexOf(s.charAt(i));
				if (v < 0) continue;
				buf = (buf << 6) | v;
				bits += 6;
				if (bits >= 8)
				{
					bits -= 8;
					out.writeByte((buf >> bits) & 0xFF);
				}
			}
			out.position = 0;
			return out;
		}

		/** ABC of tools/so-shim/bwekh/*.as (see tools/so-shim/README.txt) */
		private static const SHIMS:Array = [
			"EAAuAAAAAAwFU3RhZ2UNZmxhc2guZGlzcGxheQVzdGFnZQAXX19nb190b19kZWZpbml0aW9uX2hlbHADcG9zAzQyMAtTdGFnZUhv" +
			"bGRlcgVid2VraAZPYmplY3QDMzg1BBYCFgQWCQAFBwEBBwIDBwMIBwIKAwAAAAAAAAAAAAAAAAIFAQYHBQEGCwEDBAEAAgABAQJA" +
			"AAEAAQABAAEDRAAAAQEDAQABAAABRwAAAgEBAAEG0DDQSQBHAAAAAwEAAg7QMGUAYAQqMFgAHWgDRwAA",
			"EAAuAAAAABkLU3ByaXRlUGxhaW4FYndla2gGU3ByaXRlDWZsYXNoLmRpc3BsYXkXX19nb190b19kZWZpbml0aW9uX2hlbHADcG9z" +
			"AzI5MBxfX2dvX3RvX2N0b3JfZGVmaW5pdGlvbl9oZWxwAzMzODMvaG9tZS9jbGF1ZGUvZnBhL3Rvb2xzL3NvLXNoaW07Yndla2g7" +
			"U3ByaXRlUGxhaW4uYXMKbG9hZGVySW5mbwAMc2hhcmVkRXZlbnRzCVRleHRFdmVudAxmbGFzaC5ldmVudHMrbWFpbiBjbGFzcyAo" +
			"cGxhaW4gYmFzZSk6IGNvbnN0cnVjdG9yIHN0YXJ0cw1kaXNwYXRjaEV2ZW50BUVycm9yAWUGT2JqZWN0D0V2ZW50RGlzcGF0Y2hl" +
			"cg1EaXNwbGF5T2JqZWN0EUludGVyYWN0aXZlT2JqZWN0FkRpc3BsYXlPYmplY3RDb250YWluZXIGFgIWBBYMFg8XAgAOBwEBBwID" +
			"BwMLBwMNBwQOBwMRBwMSBwUTBwMUBwQVBwIWBwIXBwIYAwAAAAAAAAEAAAAAAAIFAQYHCAEGCQEBAgEAAQACAAEAAQFEAAACAAED" +
			"AQYDAAI00DDxCvAO0EkAYAMSFAAAYAPwD2YEXQUsAicnLBBKBQRPBgEQDAAA0DBaACrWKjArbQEdRwEJIycHCAACAAEAAAFHAAAA" +
			"AwEAByLQMGUAYAkwYAowYAswYAwwYA0wYAIqMFgAHR0dHR0daAFHAAA=",
			"EAAuAAAAAFEHQm9vbGVhbgAGT2JqZWN0Em1hcnNoYWxsRXhjZXB0aW9ucxdfX2dvX3RvX2RlZmluaXRpb25faGVscANwb3MDNTEw" +
			"B2Nvb2tpZXMXYndla2g6RXh0ZXJuYWxJbnRlcmZhY2UDNTY3CWF2YWlsYWJsZQM2MTMIb2JqZWN0SUQDNzkyC2FkZENhbGxiYWNr" +
			"Azk2MwRjYWxsBDExNzUEZmlsZQQyMTM5BGxvYWQEMjI4MARzYXZlBDI2OTMRRXh0ZXJuYWxJbnRlcmZhY2UFYndla2gDNDY5OS9o" +
			"b21lL2NsYXVkZS9mcGEvdG9vbHMvc28tc2hpbTtid2VraDtFeHRlcm5hbEludGVyZmFjZS5hcxNnZXREZWZpbml0aW9uQnlOYW1l" +
			"C2ZsYXNoLnV0aWxzIGZsYXNoLmV4dGVybmFsLkV4dGVybmFsSW50ZXJmYWNlH0ZpbGVQcml2YXRlTlM6RXh0ZXJuYWxJbnRlcmZh" +
			"Y2UhaHR0cDovL2Fkb2JlLmNvbS9BUzMvMjAwNi9idWlsdGluBUVycm9yAWUGU3RyaW5nDGZ1bmN0aW9uTmFtZQdjbG9zdXJlCEZ1" +
			"bmN0aW9uBHZvaWQEYXJncwFmA2tleQF2BGRheXMEcmVhbAt0b0xvd2VyQ2FzZQZjb29raWUHaW5kZXhPZgZsZW5ndGgGUmVnRXhw" +
			"IShzZXR8d3JpdGV8c2F2ZXxjcmVhdGV8cHV0fHN0b3JlKQR0ZXN0Bk51bWJlchsoZXJhc2V8ZGVsZXRlfHJlbW92ZXxjbGVhcikP" +
			"KGdldHxyZWFkfGxvYWQpBmNvbmNhdAVhcHBseQFkDFNoYXJlZE9iamVjdAZmb2xkZXILY29va2llcy5hbWYLcmVzb2x2ZVBhdGgC" +
			"ZnMBYgFvBmV4aXN0cwpmaWxlU3RyZWFtBHJlYWQEb3BlbglCeXRlQXJyYXkJcmVhZEJ5dGVzBWNsb3NlCHBvc2l0aW9uCnJlYWRP" +
			"YmplY3QGcGFyZW50D2NyZWF0ZURpcmVjdG9yeQt3cml0ZU9iamVjdAV3cml0ZQp3cml0ZUJ5dGVzChYCBQkWGhYeGgkaAxcaBSAI" +
			"IQIIAgUGAwcIAQkvBwEBBwEDBwEEBwIIBwELBwENBwEPBwERBwITBwIVBwIXBwMZBwQdCQsBBwEiBwcjCQ0BBwEkCQ8BBwEnBwEo" +
			"BwEvBwExBwEyGwEHATMHATUHATYJEQEHATkJOgEHAzwHAT0JPwEJQwEHB0QJRgEHBEcJSAEJSQEHAUoHAUsJTAEJTQEHAU4JUAEK" +
			"AAAAAAABCwAAEg0AAhUSFA+AJSYBABIRhCUAAhMAABUVAAAVFwAAAAAAAAAAAAoFAQYHBQEGCgUBBgwFAQYOBQEGEAUBBhIFAQYU" +
			"BQEGFgUBBhgFAQYbAQwCAQAJAAgJA0AAAQoKAQAEQAACAAEBBUIAAQECBkIAAgEDB0EAAwEECEEABAEFCUEABQEGCkEABgEHC0EA" +
			"BwEIAQABDEQAAAEJCgEDBAACJtAw8RxdDfATLB9GDQFmDtbSSBAOAADQMFoAKtcqMCttAR3wFCdIAQQSFg8QAAIDBAACJtAw8Rxd" +
			"DfAZLB9GDQFmEdbSSBAOAADQMFoAKtcqMCttAR3wGiBIAQQSFg8QAAMDBQACLtAw8RzvASUAAO8BJgEAXQ3wHywfRg0B0dJPEwIQ" +
			"DQAA0DBaACpjBCowK20BHUcBDhwgDxAABAUKAAGDA9Aw8RzvASUAAO8BKQEA7wEqAgDvASsDAO8BLAQA7wEtBQDvAS4GANESCgAA" +
			"0fAkRhYAEAIAACwChdfT8CUsMEYXASQAsCoSBwAAKdNmGCQorSoSCQAAKdJmGCQBsPAlEgIBAF0K8CdPCgBgEmTS8CgkAGYZQQGF" +
			"YwRgGvApLDRCAdNGGwEqEgkAACnSZhgkArDwKRJ9AADS8CskAWYZYwXS8CxmGCQDDw4AAGAcZNIkAmYZQQEQAgAAJAF1YwZiBfAt" +
			"IKwqEQUAACliBSGsKhELAAApYBJkYgVBASwCqyoRCAAAKWIGJACt8C0SCwAAYARiBGoZKRAPAABgBGIEYBLwLmRiBUEBYRldC/Av" +
			"TwsA8DAgSGAa8DIsN0IB00YbAfAyEhQAAGAEYgTwNGoZKV0L8DVPCwDwNiBIYBrwOCw4QgHTRhsB8DgSGQAAYARiBPA6ZhkhGQoA" +
			"AGAEYgRmGRABAAAgSF0N8D0sH0YNAYACKmMH8D5mHSDRVgHSRh4BRh8CSAAABQICAAEm0DDxHO8BOwAAYCDwQ0YhAIAC1dESDAAA" +
			"0fBELD5GIgEQAQAAIEgAAAYDBwACpAHQMPEc7wEqAADvAUABAO8BQQIA7wFCAwBgBBIFAADwSUfwSlUAXgQrYQRdCfBNRgkAgALV" +
			"0fBOlioRBQAAKdFmI5YSAQAAR2Ag8E9GJACAAtbS0fBQLEVPJQJdJvBRSiYAgCbX0tPwUk8nAdLwU08oANPwVCQAYSnT8FVGKgCA" +
			"AipjBBILAABiBF4E8FYrYQTwSxANAADQMFoAKmMGKjArbQEdRwEqkgGWAQ8QAAcDBgACc9Aw8RzvASoAAO8BQQEA7wFAAgBdCfBf" +
			"RgkAgALV0fBgEQEAAEfR8GFmK08sAF0m8GJKJgCAJtbSYATwY08tAWAg8GRGJACAAtfT0fBlLE9PJQLT0vBmTy4B0/BnTygA8F0Q" +
			"DQAA0DBaACpjBSowK20BHUcBE2FlDxAACAABAAABRwAACQEBAAEG0DDQSQBHAAAAAwEAAg7QMGUAYAIqMFgAHWgMRwAA",
			"EAAuAAIAAAA3A2ludAAFZWFybHkQYndla2g6U3ByaXRlQmFzZRdfX2dvX3RvX2RlZmluaXRpb25faGVscANwb3MDNjMzBmZyYW1l" +
			"cwM2NjIEbm90ZQM4OTQHb25BZGRlZAQxMDY4B29uRnJhbWUEMTI0NwVzdGFnZQQxNDcxClNwcml0ZUJhc2UFYndla2gGU3ByaXRl" +
			"DWZsYXNoLmRpc3BsYXkDNTkwHF9fZ29fdG9fY3Rvcl9kZWZpbml0aW9uX2hlbHADNjk3Mi9ob21lL2NsYXVkZS9mcGEvdG9vbHMv" +
			"c28tc2hpbTtid2VraDtTcHJpdGVCYXNlLmFzAXMKbG9hZGVySW5mbwxzaGFyZWRFdmVudHMJVGV4dEV2ZW50DGZsYXNoLmV2ZW50" +
			"cw1kaXNwYXRjaEV2ZW50BUVycm9yAWUGU3RyaW5nBHZvaWQTcmVtb3ZlRXZlbnRMaXN0ZW5lcgxhZGRlZFRvU3RhZ2UabWFpbiBj" +
			"bGFzczogb24gdGhlIHN0YWdlICgWIGVhcmx5IHN0YWdlIGxvb2stdXBzKQVFdmVudAplbnRlckZyYW1lEm1haW4gY2xhc3M6IGZy" +
			"YW1lIAssIG9uIHN0YWdlIAVTdGFnZS1tYWluIGNsYXNzOiBzdGFnZSBhc2tlZCBiZWZvcmUgaXQgaXMgYWRkZWQgKCMBKQZsb2Fk" +
			"ZXIebWFpbiBjbGFzczogY29uc3RydWN0b3Igc3RhcnRzEGFkZEV2ZW50TGlzdGVuZXIGT2JqZWN0D0V2ZW50RGlzcGF0Y2hlcg1E" +
			"aXNwbGF5T2JqZWN0EUludGVyYWN0aXZlT2JqZWN0FkRpc3BsYXlPYmplY3RDb250YWluZXIHFgIFBBYTFhUWHhcTABwHAQEHAgMH" +
			"AggHAgoHAgwHAg4HARAHAxIHBBQHARsHARwHBR0HAR8HASAHBiEHASIHASMHASQHBSgHBCwHAS8HATEHATIHBTMHBDQHBDUHBDYH" +
			"AAAAAAEREAqAGgEREwyAIQEREw6AIQAUEAAAABIAAAAAAAgFAQYHBQEGCQUBBgsFAQYNBQEGDwUBBhEFAQYWFwEGGAEICQEABQYC" +
			"QAABAQMBAANAAAEBAwEBBEEAAQECBUEAAgEDBkEAAwEEB2IABAEFBgABAAEIRAAAAgYHBwEGBAACM9Aw8RnvARoAAGAKEhMAAGAK" +
			"8B5mC10MLBMnJ9FKDARPDQEQDAAA0DBaACrXKjArbQEdRwEJIiYODwACAwIAASTQMPEZ7wEhAABdEvAjLCVgBU8SAl0E8CQsJmAC" +
			"oCwnoE8EAUcAAAMEAgABPtAw8RnvASEAAF0D8ClmA5EqXQMrYQMkAw4KAABdEiwpYAZPEgJHXQTwKiwqYAOgLCugXQcEByCrlqBP" +
			"BAFHAAAEAwUAAoEB0DDxGe8BGgAAXQcEB/AvgBTV0RIEAADR8DBIXQLwMWYCdZFdAithAmAC8DIkA64qEQoAAClgAiXoB6QkAKsS" +
			"DQAAXQQsLWACoCwuoE8EAWAKKhIHAAApYArwNWYVEgsAAGAKZhVmB9fTSPAzEA8AANAwWgAqYwQqMCttAR3wOCBIAU9scA4PAAUD" +
			"AQABKdAw8RnwFtBJAF0E8BcsME8EAV0W8BgsJWAFTxYCXRbwGSwpYAZPFgJHAAAGAAEAAAFHAAAAAwEAByLQMGUAYBcwYBgwYBkw" +
			"YBowYBswYAkqMFgAHR0dHR0daAhHAAA=",
			"EAAuAAMDAAAAmAEEdWludAAGT2JqZWN0B0Jvb2xlYW4VZGVmYXVsdE9iamVjdEVuY29kaW5nF19fZ29fdG9fZGVmaW5pdGlvbl9o" +
			"ZWxwA3BvcwM2MzMDZGlyEmJ3ZWtoOlNoYXJlZE9iamVjdAM2ODYIZGlyVHJpZWQDNzE5A2FsbAM3NjYKc3RvcmFnZURpcgVid2Vr" +
			"aAQxMTQ3CmZpbGVTdHJlYW0EMTI4NwZmb2xkZXIEMTUxMAdzYXZlRGlyBDE1ODIEc2FmZQQyMDUzCGdldExvY2FsBDIxNjUJZ2V0" +
			"UmVtb3RlBDI2OTAJZGVsZXRlQWxsBDI5MDQMZ2V0RGlza1VzYWdlBDI5NzAIZmx1c2hBbGwEMzEyNQZOdW1iZXIGU3RyaW5nBGRh" +
			"dGEDNzk3BmNsaWVudAM4MjgOb2JqZWN0RW5jb2RpbmcDODU2A2ZwcwM4OTQEZmlsZQM5MjQDa2V5Azk1MQhyZWFkRmlsZQQzMzA3" +
			"B3JlYWRPbGQEMzgwNwl3cml0ZUZpbGUENDE4OQVmbHVzaAQ0NjI5BWNsZWFyBDQ3MjgFY2xvc2UENDg4OAdjb25uZWN0BDQ5MjME" +
			"c2VuZAQ1MDAxCHNldERpcnR5BDUwNDILc2V0UHJvcGVydHkENTA5OQRzaXplBDUyMjAMU2hhcmVkT2JqZWN0D0V2ZW50RGlzcGF0" +
			"Y2hlcgxmbGFzaC5ldmVudHMDNTczHF9fZ29fdG9fY3Rvcl9kZWZpbml0aW9uX2hlbHADOTgyNC9ob21lL2NsYXVkZS9mcGEvdG9v" +
			"bHMvc28tc2hpbTtid2VraDtTaGFyZWRPYmplY3QuYXMTZ2V0RGVmaW5pdGlvbkJ5TmFtZQtmbGFzaC51dGlscxVmbGFzaC5maWxl" +
			"c3lzdGVtLkZpbGUbYXBwbGljYXRpb25TdG9yYWdlRGlyZWN0b3J5HGZsYXNoLmV2ZW50czpFdmVudERpc3BhdGNoZXIaRmlsZVBy" +
			"aXZhdGVOUzpTaGFyZWRPYmplY3QhaHR0cDovL2Fkb2JlLmNvbS9BUzMvMjAwNi9idWlsdGluAUMbZmxhc2guZmlsZXN5c3RlbS5G" +
			"aWxlU3RyZWFtBUNsYXNzA2N1cgJmcwRuYW1lFXNhdmVzLWFzMy9jdXJyZW50LnR4dAtyZXNvbHZlUGF0aARyZWFkBG9wZW4OYnl0" +
			"ZXNBdmFpbGFibGUMcmVhZFVURkJ5dGVzBlJlZ0V4cAleXHMrfFxzKyQBZwdyZXBsYWNlCnNhdmVzLWFzMy8FRXJyb3IBZQFzEFte" +
			"QS1aYS16MC05Ll8tXSsBXwlsb2NhbFBhdGgGc2VjdXJlAWsCc28BZAF8BC5hbWYKcmVtb3RlUGF0aAtwZXJzaXN0ZW5jZQdyZW1v" +
			"dGU6A3VybANpbnQBbgFiAW8GZXhpc3RzCUJ5dGVBcnJheQlyZWFkQnl0ZXMIcG9zaXRpb24KcmVhZE9iamVjdAZvYmplY3QEcmVh" +
			"bANvbGQBcBZmbGFzaC5uZXQuU2hhcmVkT2JqZWN0BHZvaWQDdG1wC3dyaXRlT2JqZWN0BnBhcmVudA9jcmVhdGVEaXJlY3RvcnkE" +
			"LnRtcAV3cml0ZQp3cml0ZUJ5dGVzBm1vdmVUbwxtaW5EaXNrU3BhY2UHZmx1c2hlZApkZWxldGVGaWxlDG15Q29ubmVjdGlvbgZw" +
			"YXJhbXMEYXJncwxwcm9wZXJ0eU5hbWUFdmFsdWUGbGVuZ3RoDRYCBQoXERYRFksWURoKGlQaAwVVCFYYCgQJAgcICQQDCgELCgIH" +
			"CAkEAwoBCwwKAgwHCAkEAwoBC0oHAQEHAQMHAQQHAQUHAgkHAgwHAg4HAxAHAxMHARUHAhcHAhkHARsHAR0HAR8HASEHASMHASUH" +
			"ASYHAScHASkHASsHAS0HAi8HAjEHAjMHAjUHAjcHATkHATsHAT0HAT8HAUEHAUMHAUUHAUcHBEkHBUoHBlAJUwEHAVkJXgEJYAEJ" +
			"YQEJYgEJPQEHAWMHAWYHAWgHA2kbAgleAgcBeAl8AwlgAwcGfQl+Awk9AwcBfwcBgAEJGwMJJwMbAwcBhgEHAYgBCYkBAwmKAQMJ" +
			"XAMJXgMJjQEDCY4BAwmRAQMHAZcBGAAAAAAAAhAAAAITAAACFQAAAhcAARMTGYBqAyUTEwMbiAIMDAoKXG1uBCUTEwIDHYgDDAwK" +
			"CgoKXHR1bgE1Ex+AdwE1EyGAdwA1IwAAAzMAA0ATEwM1gFxtbgADNwABEzU5iAECA48BAEA7AABAPQACQAITP4gBDAySAZMBAEBB" +
			"hAFAE0OAlQECQBMCRYgBDAyVAZYBAAFHAAAAAAAAAEkAIQYBBwgGAQcLBgEHDQYBBw8GAQcSBgEHFAYBBxYGAQcYBgEHGgYBBxwG" +
			"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" +
			"HR1oJUcAAA==",
			"EAAuAAAAABoFU3RhZ2UNZmxhc2guZGlzcGxheQhhcHBTdGFnZQVid2VraDAvaG9tZS9jbGF1ZGUvZnBhL3Rvb2xzL3NvLXNoaW07" +
			"Yndla2g7YXBwU3RhZ2UuYXMEaGVsZAJuYQF3E2dldERlZmluaXRpb25CeU5hbWULZmxhc2gudXRpbHMRYndla2guU3RhZ2VIb2xk" +
			"ZXIFc3RhZ2UWRmlsZVByaXZhdGVOUzphcHBTdGFnZQAhaHR0cDovL2Fkb2JlLmNvbS9BUzMvMjAwNi9idWlsdGluH2ZsYXNoLmRl" +
			"c2t0b3AuTmF0aXZlQXBwbGljYXRpb24RbmF0aXZlQXBwbGljYXRpb24GT2JqZWN0DGFjdGl2ZVdpbmRvdw1vcGVuZWRXaW5kb3dz" +
			"Bmxlbmd0aAVFcnJvcgJlMAFlF2FwcFN0YWdlLmFzJDA6YW5vbnltb3VzCBYCFgQWChcEBQ0WDggPAgUCBAUGBw4HAQEHAgMHAwkJ" +
			"DAEJEQEHBhIJEwEJFAEJFQEbAQcGFgcEFwcEGAIAAAAAAAEZAAAAAQABAgAAAQACAQMKAAGmAfEF7wEGAADvAQcBAO8BCAIAXQPw" +
			"ECwLRgMBZgRgAYeAAdXREgkAANHwESpjBUjwDhALAABaACpjBiowK20BHV0D8BgsEEYDAWYFgAbW0vAZZgeABtfT8BqWKhIEAAAp" +
			"0mYIKhIGAAAp0mYIZgkSCgAA0mYIJABmCoAG19MSDAAA0/AbZgRgAYcQAQAAICpjCEjwFhANAABaASpjCSowK20BHfAgIEgCETA0" +
			"Cww/kwGXAQsNAAACAQABEdAw8AxAAfAM0EEAXgIrYQJHAAA=",
			"EAAuAAAAABoOTW92aWVDbGlwUGxhaW4FYndla2gJTW92aWVDbGlwDWZsYXNoLmRpc3BsYXkXX19nb190b19kZWZpbml0aW9uX2hl" +
			"bHADcG9zAzI5MxxfX2dvX3RvX2N0b3JfZGVmaW5pdGlvbl9oZWxwAzM0NzYvaG9tZS9jbGF1ZGUvZnBhL3Rvb2xzL3NvLXNoaW07" +
			"Yndla2g7TW92aWVDbGlwUGxhaW4uYXMKbG9hZGVySW5mbwAMc2hhcmVkRXZlbnRzCVRleHRFdmVudAxmbGFzaC5ldmVudHMrbWFp" +
			"biBjbGFzcyAocGxhaW4gYmFzZSk6IGNvbnN0cnVjdG9yIHN0YXJ0cw1kaXNwYXRjaEV2ZW50BUVycm9yAWUGT2JqZWN0D0V2ZW50" +
			"RGlzcGF0Y2hlcg1EaXNwbGF5T2JqZWN0EUludGVyYWN0aXZlT2JqZWN0FkRpc3BsYXlPYmplY3RDb250YWluZXIGU3ByaXRlBhYC" +
			"FgQWDBYPFwIADwcBAQcCAwcDCwcDDQcEDgcDEQcDEgcFEwcDFAcEFQcCFgcCFwcCGAcCGQMAAAAAAAABAAAAAAACBQEGBwgBBgkB" +
			"AQIBAAEAAgABAAEBRAAAAgABAwEGAwACNNAw8QrwDtBJAGADEhQAAGAD8A9mBF0FLAInJywQSgUETwYBEAwAANAwWgAq1iowK20B" +
			"HUcBCSMnBwgAAgABAAABRwAAAAMBAAgm0DBlAGAJMGAKMGALMGAMMGANMGAOMGACKjBYAB0dHR0dHR1oAUcAAA==",
			"EAAuAAIAAAA4A2ludAAFZWFybHkTYndla2g6TW92aWVDbGlwQmFzZRdfX2dvX3RvX2RlZmluaXRpb25faGVscANwb3MDNjQyBmZy" +
			"YW1lcwM2NzEEbm90ZQM5MDYHb25BZGRlZAQxMDgwB29uRnJhbWUEMTI1OQVzdGFnZQQxNDgzDU1vdmllQ2xpcEJhc2UFYndla2gJ" +
			"TW92aWVDbGlwDWZsYXNoLmRpc3BsYXkDNTkzHF9fZ29fdG9fY3Rvcl9kZWZpbml0aW9uX2hlbHADNzA2NS9ob21lL2NsYXVkZS9m" +
			"cGEvdG9vbHMvc28tc2hpbTtid2VraDtNb3ZpZUNsaXBCYXNlLmFzAXMKbG9hZGVySW5mbwxzaGFyZWRFdmVudHMJVGV4dEV2ZW50" +
			"DGZsYXNoLmV2ZW50cw1kaXNwYXRjaEV2ZW50BUVycm9yAWUGU3RyaW5nBHZvaWQTcmVtb3ZlRXZlbnRMaXN0ZW5lcgxhZGRlZFRv" +
			"U3RhZ2UabWFpbiBjbGFzczogb24gdGhlIHN0YWdlICgWIGVhcmx5IHN0YWdlIGxvb2stdXBzKQVFdmVudAplbnRlckZyYW1lEm1h" +
			"aW4gY2xhc3M6IGZyYW1lIAssIG9uIHN0YWdlIAVTdGFnZS1tYWluIGNsYXNzOiBzdGFnZSBhc2tlZCBiZWZvcmUgaXQgaXMgYWRk" +
			"ZWQgKCMBKQZsb2FkZXIebWFpbiBjbGFzczogY29uc3RydWN0b3Igc3RhcnRzEGFkZEV2ZW50TGlzdGVuZXIGT2JqZWN0D0V2ZW50" +
			"RGlzcGF0Y2hlcg1EaXNwbGF5T2JqZWN0EUludGVyYWN0aXZlT2JqZWN0FkRpc3BsYXlPYmplY3RDb250YWluZXIGU3ByaXRlBxYC" +
			"BQQWExYVFh4XEwAdBwEBBwIDBwIIBwIKBwIMBwIOBwEQBwMSBwQUBwEbBwEcBwUdBwEfBwEgBwYhBwEiBwEjBwEkBwUoBwQsBwEv" +
			"BwExBwEyBwUzBwQ0BwQ1BwQ2BwQ3BwAAAAABERAKgBoBERMMgCEBERMOgCEAFBAAAAASAAAAAAAIBQEGBwUBBgkFAQYLBQEGDQUB" +
			"Bg8FAQYRBQEGFhcBBhgBCAkBAAUGAkAAAQEDAQADQAABAQMBAQRBAAEBAgVBAAIBAwZBAAMBBAdiAAQBBQYAAQABCEQAAAIGBwcB" +
			"BgQAAjPQMPEZ7wEaAABgChITAABgCvAeZgtdDCwTJyfRSgwETw0BEAwAANAwWgAq1yowK20BHUcBCSImDg8AAgMCAAEk0DDxGe8B" +
			"IQAAXRLwIywlYAVPEgJdBPAkLCZgAqAsJ6BPBAFHAAADBAIAAT7QMPEZ7wEhAABdA/ApZgORKl0DK2EDJAMOCgAAXRIsKWAGTxIC" +
			"R10E8CosKmADoCwroF0HBAcgq5agTwQBRwAABAMFAAKBAdAw8RnvARoAAF0HBAfwL4AU1dESBAAA0fAwSF0C8DFmAnWRXQIrYQJg" +
			"AvAyJAOuKhEKAAApYAIl6AekJACrEg0AAF0ELC1gAqAsLqBPBAFgCioSBwAAKWAK8DVmFRILAABgCmYVZgfX00jwMxAPAADQMFoA" +
			"KmMEKjArbQEd8DggSAFPbHAODwAFAwEAASnQMPEZ8BbQSQBdBPAXLDBPBAFdFvAYLCVgBU8WAl0W8BksKWAGTxYCRwAABgABAAAB" +
			"RwAAAAMBAAgm0DBlAGAXMGAYMGAZMGAaMGAbMGAcMGAJKjBYAB0dHR0dHR1oCEcAAA=="
		];
	}
}
