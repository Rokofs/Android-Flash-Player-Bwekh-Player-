package fp
{
	import flash.display.DisplayObject;
	import flash.display.DisplayObjectContainer;
	import flash.display.FrameLabel;
	import flash.display.InteractiveObject;
	import flash.display.MovieClip;
	import flash.events.MouseEvent;
	import flash.media.SoundMixer;
	import flash.utils.ByteArray;
	import flash.utils.Dictionary;
	import flash.utils.Endian;

	import fp.avm1.AbcGen;
	import fp.avm1.Avm1Data;
	import fp.avm1.Vm;
	import fp.avm1.KeyScan;

	/**
	 * Old Flash files (ActionScript 1/2) on AIR for Android, which has no AVM1.
	 *
	 * The file is rewritten as an ActionScript 3 movie without code: the timeline, graphics,
	 * text, sounds and nested clips play as usual, but AS1/AS2 scripts don't run. A tiny AVM1
	 * reader keeps what can be expressed without running code — timeline control:
	 * stop(), play(), gotoAndPlay/gotoAndStop(frame or label), next/prevFrame, stopAllSounds,
	 * aimed at this clip, _root or _parent — in frame scripts of every clip and in buttons
	 * (on press / release). They're added back as AS3 frame scripts and click handlers once
	 * the movie is loaded (apply() and hook()). Variables, conditions, text, counters — no.
	 */
	public class SwfConvert
	{
		/** converted SWF (uncompressed FWS), null when the input isn't a SWF */
		public var swf:ByteArray;
		public var totalFrames:int = 0;
		public var droppedScripts:int = 0;
		/** empty SoundStreamHead tags removed */
		public var droppedStreams:int = 0;
		/** timeline StartSound tags handed to the AVM1 engine */
		public var movedSounds:int = 0;
		/** main timeline: frame -> steps */
		public var scripts:Object = {};

		/** button character id -> steps run on click */
		private var buttonActions:Object = {};
		/** sprite id -> { frame -> steps } */
		private var spriteScripts:Object = {};
		/** instance name -> steps (buttons) */
		public var buttons:Object = {};
		/** instance name -> sprite id (clips with frame scripts) */
		private var clips:Object = {};
		/** main timeline frames that show a working button */
		private var rootHasButton:Object = {};
		private var nameCounter:int = 0;
		private var sawAttributes:Boolean = false;

		/** code mode (AVM1 engine): keep the AS1/AS2 code here instead of reading simple scripts */
		public var data:Avm1Data;
		/** keyboard keys the AS1/AS2 code reads (key codes, first-mentioned first); code mode only */
		public var keys:Array = [];
		private var version:int = 6;
		private var abcTag:ByteArray;
		private var abcWritten:Boolean = false;
		/** ids defined in the current main timeline frame, for SymbolClass */
		private var frameSymbols:Array = [];

		/** keepCode: collect the code for the AVM1 engine (otherwise: simple timeline scripts only). */
		public static function convert(src:ByteArray, keepCode:Boolean = false):SwfConvert
		{
			var c:SwfConvert = new SwfConvert();
			var body:ByteArray = SwfBytes.decompress(src);
			if (!body) return null;
			src.position = 3;
			var version:int = src.readUnsignedByte();
			src.position = 0;
			c.version = version;
			Vm.stringVersion = version;
			if (keepCode)
			{
				c.data = new Avm1Data();
				c.data.version = version;
				c.data.source = body;
				c.prescan(body);
			}

			// header: RECT + frame rate + frame count
			var nbits:int = body[0] >> 3;
			var headLen:int = Math.ceil((5 + nbits * 4) / 8) + 4;
			var out:ByteArray = new ByteArray();
			out.endian = Endian.LITTLE_ENDIAN;
			out.writeBytes(body, 0, headLen);

			body.position = headLen;
			var root:Object = { top: true, id: 0, depths: {}, scripts: c.scripts, hasButton: c.rootHasButton };
			var tags:ByteArray = c.rewriteTags(body, body.length, root);

			// FileAttributes must be the first tag: AS3 on
			if (!c.sawAttributes) writeTag(out, 69, bytesOf([0x08, 0, 0, 0]));
			out.writeBytes(tags);

			var swf:ByteArray = new ByteArray();
			swf.endian = Endian.LITTLE_ENDIAN;
			swf.writeUTFBytes("FWS");
			swf.writeByte(Math.max(9, version));
			swf.writeUnsignedInt(out.length + 8);
			swf.writeBytes(out);
			swf.position = 0;
			c.swf = swf;
			if (c.data)
			{
				// keys the code reads: the on-screen gamepad offers them
				try
				{
					var ks:KeyScan = new KeyScan();
					for each (var conds:Array in c.data.buttonConds)
						for each (var bc:Object in conds) if (bc.key) ks.addKeyPress(bc.key);
					ks.scanAll(c.data.origins);
					c.keys = ks.keys;
				}
				catch (ke:Error) {}
			}
			return c;
		}

		/** Copy tags, dropping AVM1 code. tl = the timeline being read {top, depths, scripts, hasButton}. */
		/** offset (in the uncompressed body) of the data of the tag being read */
		private var tagBase:int = 0;

		private function rewriteTags(b:ByteArray, end:uint, tl:Object, base:int = 0):ByteArray
		{
			var out:ByteArray = new ByteArray();
			out.endian = Endian.LITTLE_ENDIAN;
			var frame:int = 1;
			var placedThisFrame:Boolean = false;
			while (b.position + 2 <= end)
			{
				var header:uint = b.readUnsignedShort();
				var code:uint = header >> 6;
				var len:uint = header & 0x3F;
				if (len == 0x3F)
				{
					if (b.position + 4 > end) break;
					len = b.readUnsignedInt();
				}
				var start:uint = b.position;
				if (start + len > end) break;
				var data:ByteArray = new ByteArray();
				data.endian = Endian.LITTLE_ENDIAN;
				if (len > 0) data.writeBytes(b, start, len);
				b.position = start + len;
				tagBase = base + start;

				// code mode: our AS3 classes go right after FileAttributes
				if (this.data && tl.top && !abcWritten && code != 69)
				{
					abcWritten = true;
					writeTag(out, 82, abcTag);
				}
				switch (code)
				{
					case 69: // FileAttributes: switch on ActionScript 3
						if (tl.top)
						{
							sawAttributes = true;
							if (data.length >= 1) data[0] = (data[0] | 0x08);
							writeTag(out, code, data);
						}
						break;
					case 12: // DoAction
						if (this.data)
						{
							if (!placedThisFrame)
							{
								if (!this.data.actionsFirst[tl.id]) this.data.actionsFirst[tl.id] = {};
								this.data.actionsFirst[tl.id][frame] = true;
							}
							this.data.addFrameAction(tl.id, frame, data);
							this.data.setOrigin(data, tagBase);
						}
						else
						{
							var steps:Array = parseActions(data);
							if (steps) tl.scripts[frame] = steps;
						}
						droppedScripts++;
						break;
					case 59: // DoInitAction: sprite id, actions
						if (this.data && data.length > 2)
						{
							var ia:ByteArray = new ByteArray();
							ia.writeBytes(data, 2, data.length - 2);
							this.data.setOrigin(ia, tagBase + 2);
							this.data.initActions.push({ id: data[0] | (data[1] << 8), code: ia });
						}
						droppedScripts++;
						break;
					case 7: // DefineButton
						if (this.data) codeButton1(data); else readButton1(data);
						noteSymbol(data[0] | (data[1] << 8));
						writeTag(out, code, data);
						break;
					case 34: // DefineButton2
						if (this.data) codeButton2(data); else readButton2(data);
						noteSymbol(data[0] | (data[1] << 8));
						writeTag(out, code, data);
						break;
					case 48: // DefineFont2
					case 75: // DefineFont3
						noteSymbol(data[0] | (data[1] << 8));
						writeTag(out, code, data);
						break;
					case 14: // DefineSound
						noteSymbol(data[0] | (data[1] << 8));
						writeTag(out, code, data);
						break;
					case 37: // DefineEditText
						if (this.data) readEditText(data);
						writeTag(out, code, data);
						break;
					case 56: // ExportAssets
						if (this.data) readExports(data);
						writeTag(out, code, data);
						break;
					case 5: // RemoveObject: char id, depth
						if (this.data) this.data.markDisplayChange(tl.id, frame);
						if (data.length >= 4) delete tl.depths[data[2] | (data[3] << 8)];
						writeTag(out, code, data);
						break;
					case 28: // RemoveObject2: depth
						if (this.data) this.data.markDisplayChange(tl.id, frame);
						if (data.length >= 2) delete tl.depths[data[0] | (data[1] << 8)];
						writeTag(out, code, data);
						break;
					case 4: // PlaceObject
						if (this.data) this.data.markDisplayChange(tl.id, frame);
						placedThisFrame = true;
						writeTag(out, code, data);
						break;
					case 26: // PlaceObject2
					case 70: // PlaceObject3
						if (this.data) this.data.markDisplayChange(tl.id, frame);
						if (data.length && (data[0] & 0x02)) placedThisFrame = true;
						if (this.data) writeTag(out, code, placeCode(data, code == 70, tl));
						else if (code == 26) writeTag(out, code, nameInstance(stripClipActions(data), false, tl));
						else writeTag(out, code, nameInstance(data, true, tl));
						break;
					case 15: // StartSound: in code mode our engine plays it (one mixer for all sounds)
						if (this.data && data.length >= 3)
						{
							var sflags:int = data[2];
							data.position = 3;
							var inPt:uint = 0, outPt:uint = 0, loopsN:int = 1;
							var env:Array = null;
							try
							{
								if (sflags & 1) inPt = data.readUnsignedInt();
								if (sflags & 2) outPt = data.readUnsignedInt();
								if (sflags & 4) loopsN = data.readUnsignedShort();
								if (sflags & 8)
								{
									// volume envelope (Edit Envelope in Flash): position in 44.1 kHz samples
									// since the sound started, left and right level 0..32768
									var np:int = data.readUnsignedByte();
									env = [];
									for (var ep:int = 0; ep < np; ep++)
									{
										env.push(data.readUnsignedInt());
										env.push(data.readUnsignedShort() / 32768);
										env.push(data.readUnsignedShort() / 32768);
									}
									if (!env.length) env = null;
								}
							}
							catch (se:Error) {}
							this.data.addFrameSound(tl.id, frame, { id: data[0] | (data[1] << 8), stop: (sflags & 0x20) != 0,
								single: (sflags & 0x10) != 0, loops: loopsN < 1 ? 1 : loopsN, inMs: inPt / 44.1,
								outMs: outPt > inPt ? outPt / 44.1 : 0, env: env });
							movedSounds++;
							break;
						}
						writeTag(out, code, data);
						break;
					case 18: // SoundStreamHead
					case 45: // SoundStreamHead2
						// Flash writes an empty stream header into every timeline. Flash Player
						// ignores it, but AIR on Android can open a stream for it that never gets
						// data and replays its buffer forever (the stuck sound): drop empty ones
						if (data.length >= 4 && (data[2] | (data[3] << 8)) == 0) { droppedStreams++; break; }
						writeTag(out, code, data);
						break;
					case 39: // DefineSprite: id, frame count, then its own tags
						var id:int = data[0] | (data[1] << 8);
						var sub:Object = { top: false, id: id, depths: {}, scripts: {}, hasButton: {} };
						if (this.data) this.data.spriteFrames[id] = data[2] | (data[3] << 8);
						noteSymbol(id);
						var spr:ByteArray = new ByteArray();
						spr.endian = Endian.LITTLE_ENDIAN;
						spr.writeBytes(data, 0, Math.min(4, data.length));
						data.position = 4;
						var sprBase:int = tagBase;
						spr.writeBytes(rewriteTags(data, data.length, sub, sprBase));
						tagBase = sprBase;
						for (var sk:String in sub.scripts)
						{
							spriteScripts[id] = sub.scripts;
							break;
						}
						writeTag(out, code, spr);
						break;
					case 1: // ShowFrame
						placedThisFrame = false;
						if (this.data && tl.top && frameSymbols.length)
						{
							writeTag(out, 76, AbcGen.symbolClassTag(frameSymbols));
							frameSymbols = [];
						}
						for (var dk:String in tl.depths)
						{
							if (buttonActions[tl.depths[dk]]) { tl.hasButton[frame] = true; break; }
						}
						frame++;
						writeTag(out, code, data);
						break;
					case 43: // FrameLabel: as the engine reads it
						var fl:ByteArray = this.data ? fixedName(data, 0) : null;
						if (fl)
						{
							var nl:ByteArray = new ByteArray();
							nl.writeBytes(fl);
							nl.writeByte(0);
							var lend:int = 0;
							while (lend < data.length && data[lend] != 0) lend++;
							if (lend + 1 < data.length) nl.writeBytes(data, lend + 1, data.length - lend - 1);
							writeTag(out, code, nl);
						}
						else writeTag(out, code, data);
						break;
					default:
						writeTag(out, code, data);
				}
				if (code == 0) break;
			}
			if (tl.top) totalFrames = frame - 1;
			return out;
		}

		// ---------------------------------------------------------------- AVM1 reader

		private static const TIMELINE_METHODS:Array = ["gotoAndPlay", "gotoAndStop", "play", "stop", "nextFrame", "prevFrame"];

		/**
		 * Steps: {op: "stop"|"play"|"goto"|"next"|"prev"|"stopsounds", t: "self"|"root"|"parent",
		 *         frame:int or label:String, play:Boolean}. null = the code does something else.
		 */
		private function parseActions(d:ByteArray):Array
		{
			d.position = 0;
			d.endian = Endian.LITTLE_ENDIAN;
			var ops:Array = [];
			var stack:Array = [];
			var pool:Array = [];
			var target:String = "self"; // tellTarget / setTarget
			try
			{
				while (d.bytesAvailable > 0)
				{
					var op:int = d.readUnsignedByte();
					if (op == 0) break;
					var len:int = 0;
					if (op >= 0x80) len = d.readUnsignedShort();
					var p:uint = d.position;
					switch (op)
					{
						case 0x07: ops.push({ op: "stop", t: target }); break;
						case 0x06: ops.push({ op: "play", t: target }); break;
						case 0x09: ops.push({ op: "stopsounds", t: target }); break;
						case 0x04: ops.push({ op: "next", t: target }); break;
						case 0x05: ops.push({ op: "prev", t: target }); break;
						case 0x81: ops.push({ op: "goto", t: target, frame: d.readUnsignedShort() + 1, play: false }); break;
						case 0x8C: ops.push({ op: "goto", t: target, label: readStr(d), play: false }); break;
						case 0x8B: // SetTarget
							target = refOf(readStr(d), true);
							if (!target) return null;
							break;
						case 0x88: // ConstantPool
							pool = [];
							var n:int = d.readUnsignedShort();
							for (var ci:int = 0; ci < n; ci++) pool.push(readStr(d));
							break;
						case 0x96: // Push
							while (d.position < p + len)
							{
								var ty:int = d.readUnsignedByte();
								if (ty == 0) stack.push(readStr(d));
								else if (ty == 1) stack.push(d.readFloat());
								else if (ty == 2 || ty == 3) stack.push(null);
								else if (ty == 5) stack.push(d.readUnsignedByte() != 0);
								else if (ty == 6) stack.push(readAvm1Double(d));
								else if (ty == 7) stack.push(d.readInt());
								else if (ty == 8) stack.push(pool[d.readUnsignedByte()]);
								else if (ty == 9) stack.push(pool[d.readUnsignedShort()]);
								else return null; // registers etc.
							}
							break;
						case 0x1C: // GetVariable: only _root / this / _parent
							var ref:String = refOf(stack.pop(), false);
							if (!ref) return null;
							stack.push({ ref: ref });
							break;
						case 0x17: // Pop
							stack.pop();
							break;
						case 0x52: // CallMethod: name, object, numArgs, args...
						case 0x3D: // CallFunction: name, numArgs, args...
							var mname:* = stack.pop();
							var t:String = target;
							if (op == 0x52)
							{
								var obj:* = stack.pop();
								if (!obj || !obj.ref) return null;
								t = obj.ref;
							}
							var argc:int = int(stack.pop());
							var args:Array = [];
							for (var ai:int = 0; ai < argc; ai++) args.push(stack.pop());
							if (TIMELINE_METHODS.indexOf(mname) < 0) return null;
							if (!timelineCall(String(mname), args, t, ops)) return null;
							stack.push(null);
							break;
						case 0x9F: // GotoFrame2: frame number (1-based) or label from the stack
							var fl:int = d.readUnsignedByte();
							if (fl & 2) return null; // scene bias
							var tg:* = stack.pop();
							if (tg is Number) ops.push({ op: "goto", t: target, frame: int(tg), play: (fl & 1) != 0 });
							else if (tg is String) ops.push({ op: "goto", t: target, label: tg, play: (fl & 1) != 0 });
							else return null;
							break;
						default:
							return null; // real code — can't run it
					}
					d.position = p + len;
				}
			}
			catch (e:Error)
			{
				return null;
			}
			// "goto" followed by "play" on the same clip = gotoAndPlay
			var res:Array = [];
			for each (var o:Object in ops)
			{
				var last:Object = res.length ? res[res.length - 1] : null;
				if (o.op == "play" && last && last.op == "goto" && last.t == o.t) last.play = true;
				else res.push(o);
			}
			return res.length ? res : null;
		}

		/** "_root" -> "root", "this" -> "self", "_parent" -> "parent"; null for anything else. */
		private static function refOf(name:*, setTarget:Boolean):String
		{
			if (name === "_root" || name === "_level0" || name === "/") return "root";
			if (name === "this" || (setTarget && name === "")) return "self";
			if (name === "_parent" || name === "..") return "parent";
			return null;
		}

		private static function timelineCall(m:String, args:Array, t:String, ops:Array):Boolean
		{
			switch (m)
			{
				case "stop": ops.push({ op: "stop", t: t }); return true;
				case "play": ops.push({ op: "play", t: t }); return true;
				case "nextFrame": ops.push({ op: "next", t: t }); return true;
				case "prevFrame": ops.push({ op: "prev", t: t }); return true;
			}
			var a:* = args[0];
			var play:Boolean = m == "gotoAndPlay";
			if (a is Number) ops.push({ op: "goto", t: t, frame: int(a), play: play });
			else if (a is String && !isNaN(Number(a))) ops.push({ op: "goto", t: t, frame: int(Number(a)), play: play });
			else if (a is String) ops.push({ op: "goto", t: t, label: a, play: play });
			else return false;
			return true;
		}

		private static function readStr(d:ByteArray):String
		{
			return Vm.readStr(d);
		}

		/** The name at d[pos] (zero-terminated) if AIR would read it differently than the engine (not
		 *  valid UTF-8 / Flash 5 text): its bytes re-encoded; null if it's fine as it is. */
		private static function fixedName(d:ByteArray, pos:int):ByteArray
		{
			var p:int = pos;
			var plain:Boolean = true;
			while (p < d.length && d[p] != 0) { if (d[p] >= 0x80) plain = false; p++; }
			if (plain) return null;
			d.position = pos;
			var s:String = Vm.readStr(d);
			var b:ByteArray = Vm.strBytes(s);
			if (b.length == p - pos)
			{
				var same:Boolean = true;
				for (var i:int = 0; i < b.length && same; i++) if (b[i] != d[pos + i]) same = false;
				if (same) return null;
			}
			return b;
		}

		/** AVM1 doubles are stored as two swapped 32-bit halves. */
		private static function readAvm1Double(d:ByteArray):Number
		{
			var a:uint = d.readUnsignedInt();
			var b:uint = d.readUnsignedInt();
			var t:ByteArray = new ByteArray();
			t.endian = Endian.LITTLE_ENDIAN;
			t.writeUnsignedInt(b);
			t.writeUnsignedInt(a);
			t.position = 0;
			return t.readDouble();
		}

		// ---------------------------------------------------------------- buttons

		private function readButton1(d:ByteArray):void
		{
			try
			{
				var id:int = d[0] | (d[1] << 8);
				// records: flags (0 = end), char id, depth, matrix
				var br:BitReader = new BitReader(d, 2);
				var p:int;
				while (true)
				{
					p = br.bytePos;
					if (p >= d.length) return;
					if (d[p] == 0) { p++; break; }
					br.skipBytes(5);
					br.skipMatrix();
				}
				var a:ByteArray = new ByteArray();
				a.writeBytes(d, p, d.length - p);
				var steps:Array = parseActions(a);
				if (steps) buttonActions[id] = steps;
			}
			catch (e:Error) {}
		}

		private function readButton2(d:ByteArray):void
		{
			try
			{
				var id:int = d[0] | (d[1] << 8);
				var off:int = d[3] | (d[4] << 8);
				if (off == 0) return;
				var p:int = 3 + off;
				while (p + 4 <= d.length)
				{
					var size:int = d[p] | (d[p + 1] << 8);
					var cond:int = d[p + 2];
					var end:int = size ? p + size : d.length;
					// OverDownToOverUp (release) = bit 3, OverUpToOverDown (press) = bit 2
					if (cond & 0x0C)
					{
						var a:ByteArray = new ByteArray();
						a.writeBytes(d, p + 4, end - p - 4);
						var steps:Array = parseActions(a);
						if (steps)
						{
							buttonActions[id] = steps;
							return;
						}
					}
					if (!size) break;
					p = end;
				}
			}
			catch (e:Error) {}
		}

		/**
		 * PlaceObject2/3: remember what is at each depth, and give buttons with actions and
		 * clips with frame scripts an instance name so we can find them in AS3 later.
		 */
		private function nameInstance(d:ByteArray, po3:Boolean, tl:Object):ByteArray
		{
			try
			{
				if (d.length < 3) return d;
				var f1:int = d[0];
				var f2:int = po3 ? d[1] : 0;
				var p:int = po3 ? 2 : 1;
				var depth:int = d[p] | (d[p + 1] << 8);
				var br:BitReader = new BitReader(d, p + 2);
				if (po3 && ((f2 & 0x08) || ((f2 & 0x10) && (f1 & 0x02)))) br.skipString(); // class name
				var charId:int = -1;
				if (f1 & 0x02)
				{
					var cp:int = br.bytePos;
					charId = d[cp] | (d[cp + 1] << 8);
					br.skipBytes(2);
					tl.depths[depth] = charId;
				}
				else if (tl.depths[depth] !== undefined)
				{
					charId = tl.depths[depth];
				}
				var isButton:Boolean = buttonActions[charId] != null;
				var isClip:Boolean = spriteScripts[charId] != null;
				if (charId < 0 || (!isButton && !isClip)) return d;
				if (f1 & 0x04) br.skipMatrix();
				if (f1 & 0x08) br.skipCxformAlpha();
				if (f1 & 0x10) br.skipBytes(2);
				var namePos:int = br.bytePos;
				var name:String;
				if (f1 & 0x20)
				{
					var tmp:ByteArray = new ByteArray();
					tmp.writeBytes(d, namePos, d.length - namePos);
					tmp.position = 0;
					name = readStr(tmp);
				}
				else if (f1 & 0x02)
				{
					name = "fpobj" + (++nameCounter);
				}
				else
				{
					return d; // a move: the earlier placement named it
				}
				if (isButton) buttons[name] = buttonActions[charId];
				else clips[name] = charId;
				if (f1 & 0x20) return d;
				var out:ByteArray = new ByteArray();
				out.writeBytes(d, 0, namePos);
				out.writeUTFBytes(name);
				out.writeByte(0);
				out.writeBytes(d, namePos, d.length - namePos);
				out[0] = f1 | 0x20;
				return out;
			}
			catch (e:Error) {}
			return d;
		}

		// ---------------------------------------------------------------- runtime

		/**
		 * Main timeline scripts. Stops (and gotoAndStop, and jumps back) in the middle of the movie
		 * are kept only where a working button is on screen; otherwise it would wait forever
		 * for a click on something whose code can't run here.
		 */
		public function apply(root:MovieClip):int
		{
			if (!root) return 0;
			var n:int = 0;
			var total:int = root.totalFrames;
			for (var k:String in scripts)
			{
				var f:int = int(k);
				if (f < 1 || f > total) continue;
				var steps:Array = [];
				for each (var s:Object in scripts[k])
				{
					var waits:Boolean = s.op == "stop" || (s.op == "goto" && !s.play);
					if (s.op == "goto" && f != total && s.t != "parent")
					{
						var to:int = s.label != null ? labelFrame(root, s.label) : s.frame;
						if (to <= 0 || to <= f) waits = true;
					}
					if (waits && f != total && !rootHasButton[f]) continue;
					steps.push(s);
				}
				if (!steps.length) continue;
				try
				{
					root.addFrameScript(f - 1, makeScript(root, root, steps));
					n++;
				}
				catch (e:Error) {}
			}
			return n;
		}

		private var hooked:Dictionary = new Dictionary(true);
		private var visited:int;

		/** Wire buttons and clip frame scripts that appeared on screen (call every frame). */
		public function hook(root:MovieClip):void
		{
			if (!root) return;
			visited = 0;
			walk(root, root, 0);
		}

		private function walk(c:DisplayObjectContainer, root:MovieClip, depth:int):void
		{
			if (depth > 12) return;
			var n:int = 0;
			try { n = c.numChildren; } catch (e:Error) { return; }
			for (var i:int = 0; i < n; i++)
			{
				if (++visited > 4000) return;
				var o:DisplayObject = null;
				try { o = c.getChildAt(i); } catch (e2:Error) {}
				if (!o) continue;
				if (!hooked[o])
				{
					var steps:Array = buttons[o.name];
					if (steps && o is InteractiveObject)
					{
						hooked[o] = true;
						var owner:MovieClip = (c as MovieClip) || root;
						o.addEventListener(MouseEvent.CLICK, makeHandler(owner, root, steps));
					}
					else if (o is MovieClip && clips[o.name] !== undefined)
					{
						hooked[o] = true;
						addClipScripts(o as MovieClip, root, spriteScripts[clips[o.name]]);
					}
				}
				var cc:DisplayObjectContainer = o as DisplayObjectContainer;
				if (cc) walk(cc, root, depth + 1);
			}
		}

		/** Frame scripts of a nested clip: kept as they are (a stop() there is usually meant). */
		private function addClipScripts(mc:MovieClip, root:MovieClip, frames:Object):void
		{
			if (!frames) return;
			var total:int = mc.totalFrames;
			for (var k:String in frames)
			{
				var f:int = int(k);
				if (f < 1 || f > total) continue;
				try { mc.addFrameScript(f - 1, makeScript(mc, root, frames[k])); } catch (e:Error) {}
			}
		}

		private static function makeHandler(owner:MovieClip, root:MovieClip, steps:Array):Function
		{
			var run:Function = makeScript(owner, root, steps);
			return function(e:MouseEvent):void { run(); };
		}

		private static function makeScript(self:MovieClip, root:MovieClip, steps:Array):Function
		{
			return function():void {
				for each (var s:Object in steps)
				{
					var mc:MovieClip = s.t == "root" ? root : s.t == "parent" ? ((self.parent as MovieClip) || root) : self;
					try
					{
						if (s.op == "stop") mc.stop();
						else if (s.op == "play") mc.play();
						else if (s.op == "next") mc.nextFrame();
						else if (s.op == "prev") mc.prevFrame();
						else if (s.op == "stopsounds") SoundMixer.stopAll();
						else if (s.op == "goto")
						{
							var target:Object = s.label != null ? s.label : Math.max(1, Math.min(mc.totalFrames, s.frame));
							if (s.play) mc.gotoAndPlay(target);
							else mc.gotoAndStop(target);
							if (mc == self) return; // our playhead moved — the rest belongs to the old frame
						}
					}
					catch (e:Error) {}
				}
			};
		}

		private static function labelFrame(mc:MovieClip, label:String):int
		{
			try
			{
				for each (var fl:FrameLabel in mc.currentLabels)
				{
					if (fl.name == label) return fl.frame;
				}
			}
			catch (e:Error) {}
			return -1;
		}

		public function get buttonCount():int
		{
			var n:int = 0;
			for (var k:String in buttons) n++;
			return n;
		}

		public function get clipCount():int
		{
			var n:int = 0;
			for (var k:String in clips) n++;
			return n;
		}

		// ---------------------------------------------------------------- code mode

		/** First pass: which characters get an AS3 class (sprites, buttons, sounds). */
		private function prescan(body:ByteArray):void
		{
			var nbits:int = body[0] >> 3;
			body.position = Math.ceil((5 + nbits * 4) / 8) + 4;
			var classes:Array = [];
			while (body.bytesAvailable >= 2)
			{
				var header:uint = body.readUnsignedShort();
				var code:uint = header >> 6;
				var len:uint = header & 0x3F;
				if (len == 0x3F) len = body.readUnsignedInt();
				var start:uint = body.position;
				if (start + len > body.length) break;
				if (len >= 2)
				{
					var id:int = body[start] | (body[start + 1] << 8);
					if (code == 39) { data.kinds[id] = "sprite"; classes.push(AbcGen.SPRITE + id); }
					else if (code == 7 || code == 34) { data.kinds[id] = "button"; classes.push(AbcGen.BUTTON + id); }
					else if (code == 14) { data.kinds[id] = "sound"; classes.push(AbcGen.SOUND + id); }
					else if (code == 48 || code == 75) { data.kinds[id] = "font"; classes.push(AbcGen.FONT + id); data.fonts.push(id); }
				}
				if (code == 0) break;
				body.position = start + len;
			}
			body.position = 0;
			abcTag = AbcGen.doAbcTag(AbcGen.build(classes));
		}

		/** A symbol was defined on the main timeline: link it to its class at the end of the frame. */
		private function noteSymbol(id:int):void
		{
			if (!data) return;
			var k:String = data.kinds[id];
			if (k == "sprite") frameSymbols.push([id, AbcGen.SPRITE + id]);
			else if (k == "button") frameSymbols.push([id, AbcGen.BUTTON + id]);
			else if (k == "sound") frameSymbols.push([id, AbcGen.SOUND + id]);
			else if (k == "font") frameSymbols.push([id, AbcGen.FONT + id]);
		}

		private function codeButton1(d:ByteArray):void
		{
			try
			{
				var id:int = d[0] | (d[1] << 8);
				var br:BitReader = new BitReader(d, 2);
				var p:int;
				while (true)
				{
					p = br.bytePos;
					if (p >= d.length) return;
					if (d[p] == 0) { p++; break; }
					br.skipBytes(5);
					br.skipMatrix();
				}
				var a:ByteArray = new ByteArray();
				a.writeBytes(d, p, d.length - p);
				data.setOrigin(a, tagBase + p);
				data.buttonConds[id] = [{ flags: 0x08, key: 0, code: a }]; // on release
			}
			catch (e:Error) {}
		}

		private function codeButton2(d:ByteArray):void
		{
			try
			{
				var id:int = d[0] | (d[1] << 8);
				var off:int = d[3] | (d[4] << 8);
				if (off == 0) return;
				var list:Array = [];
				var p:int = 3 + off;
				while (p + 4 <= d.length)
				{
					var size:int = d[p] | (d[p + 1] << 8);
					var end:int = size ? p + size : d.length;
					var a:ByteArray = new ByteArray();
					a.writeBytes(d, p + 4, end - p - 4);
					data.setOrigin(a, tagBase + p + 4);
					// flags: low byte = transitions, high byte = key code << 1 | OverDownToIdle
					list.push({ flags: d[p + 2] | ((d[p + 3] & 1) << 8), key: d[p + 3] >> 1, code: a });
					if (!size) break;
					p = end;
				}
				if (list.length) data.buttonConds[id] = list;
			}
			catch (e:Error) {}
		}

		/** DefineEditText: remember the variable a text field shows. */
		private function readEditText(d:ByteArray):void
		{
			try
			{
				var id:int = d[0] | (d[1] << 8);
				var br:BitReader = new BitReader(d, 2);
				br.skipRect();
				var p:int = br.bytePos;
				var f1:int = d[p], f2:int = d[p + 1];
				p += 2;
				if (f1 & 0x01) { p += 2; if (f2 & 0x80) { while (d[p] != 0) p++; p++; } p += 2; } // font, class, height
				else if (f2 & 0x80) { while (d[p] != 0) p++; p++; p += 2; }
				if (f1 & 0x04) p += 4;  // color
				if (f1 & 0x02) p += 2;  // max length
				if (f2 & 0x20) p += 9;  // layout
				var tmp:ByteArray = new ByteArray();
				tmp.writeBytes(d, p, d.length - p);
				tmp.position = 0;
				var v:String = readStr(tmp);
				if (v) data.textVars[id] = { v: v, html: (f2 & 0x02) != 0 };
			}
			catch (e:Error) {}
		}

		private function readExports(d:ByteArray):void
		{
			try
			{
				d.position = 0;
				var n:int = d.readUnsignedShort();
				for (var i:int = 0; i < n; i++)
				{
					var id:int = d.readUnsignedShort();
					data.exports[readStr(d)] = id;
				}
			}
			catch (e:Error) {}
		}

		/**
		 * Code mode PlaceObject2/3: take out onClipEvent handlers (kept for the engine) and make sure
		 * instances that need them (clip events, bound text fields) have a name we can find later.
		 */
		private function placeCode(d:ByteArray, po3:Boolean, tl:Object):ByteArray
		{
			try
			{
				if (d.length < 3) return d;
				var f1:int = d[0];
				var f2:int = po3 ? d[1] : 0;
				var p:int = po3 ? 2 : 1;
				var depth:int = d[p] | (d[p + 1] << 8);
				var br:BitReader = new BitReader(d, p + 2);
				if (po3 && ((f2 & 0x08) || ((f2 & 0x10) && (f1 & 0x02)))) br.skipString();
				var charId:int = -1;
				if (f1 & 0x02)
				{
					var cp:int = br.bytePos;
					charId = d[cp] | (d[cp + 1] << 8);
					br.skipBytes(2);
					tl.depths[depth] = charId;
				}
				else if (tl.depths[depth] !== undefined)
				{
					charId = tl.depths[depth];
				}
				if (f1 & 0x04) br.skipMatrix();
				if (f1 & 0x08) br.skipCxformAlpha();
				if (f1 & 0x10) br.skipBytes(2);
				var namePos:int = br.bytePos;
				var name:String = null;
				if (f1 & 0x20)
				{
					var tmp:ByteArray = new ByteArray();
					tmp.writeBytes(d, namePos, d.length - namePos);
					tmp.position = 0;
					name = readStr(tmp);
					br.skipString();
				}
				if (f1 & 0x40) br.skipBytes(2);
				if (po3)
				{
					if (f2 & 0x01) br.skipFilters();
					if (f2 & 0x02) br.skipBytes(1);
					if (f2 & 0x04) br.skipBytes(1);
					if (f2 & 0x20) br.skipBytes(1);
					if (f2 & 0x40) br.skipBytes(4);
				}
				var actPos:int = br.bytePos;
				var events:Array = (f1 & 0x80) ? readClipActions(d, actPos) : null;
				var tv:Object = charId >= 0 ? data.textVars[charId] : null;
				var needsName:Boolean = (events != null || tv != null) && (f1 & 0x02) && !(f1 & 0x20);
				if (needsName) name = "fpobj" + (++nameCounter);
				if (name != null) data.noteName(name);
				// a name AIR would read differently (obfuscated, not UTF-8): write it the engine's way
				var newName:ByteArray = (f1 & 0x20) ? fixedName(d, namePos) : null;
				if (newName)
				{
					newName.position = 0;
					data.noteName(newName.readUTFBytes(newName.length));
					var oldEnd:int = namePos;
					while (oldEnd < d.length && d[oldEnd] != 0) oldEnd++;
					oldEnd++;
					var rn:ByteArray = new ByteArray();
					rn.writeBytes(d, 0, namePos);
					rn.writeBytes(newName);
					rn.writeByte(0);
					var tailEnd:int = (f1 & 0x80) ? actPos : d.length;
					if (tailEnd > oldEnd) rn.writeBytes(d, oldEnd, tailEnd - oldEnd);
					rn[0] = f1 & 0x7F;
					if (name != null)
					{
						var key2:String = tl.id + "/" + name;
						if (events) data.clipActions[key2] = events;
						if (tv) data.placedTextVars[key2] = tv;
					}
					return rn;
				}
				if (name != null)
				{
					var key:String = tl.id + "/" + name;
					if (events) data.clipActions[key] = events;
					if (tv) data.placedTextVars[key] = tv;
				}
				if (!needsName && !(f1 & 0x80)) return d;

				var out:ByteArray = new ByteArray();
				out.writeBytes(d, 0, needsName ? namePos : (f1 & 0x80 ? actPos : d.length));
				if (needsName)
				{
					out.writeUTFBytes(name);
					out.writeByte(0);
					out.writeBytes(d, namePos, (f1 & 0x80 ? actPos : d.length) - namePos);
				}
				out[0] = ((f1 & 0x7F) | (needsName ? 0x20 : 0));
				return out;
			}
			catch (e:Error) {}
			return d;
		}

		/** CLIPACTIONS record -> [{flags, key, code}] */
		private function readClipActions(d:ByteArray, p:int):Array
		{
			var wide:Boolean = version >= 6;
			d.endian = Endian.LITTLE_ENDIAN;
			d.position = p + 2;                      // reserved
			if (wide) d.readUnsignedInt(); else d.readUnsignedShort(); // all event flags
			var list:Array = [];
			while (d.bytesAvailable >= (wide ? 4 : 2))
			{
				var flags:uint = wide ? d.readUnsignedInt() : d.readUnsignedShort();
				if (flags == 0) break;
				var size:uint = d.readUnsignedInt();
				var start:uint = d.position;
				var key:int = 0;
				if (flags & (1 << 17)) { key = d.readUnsignedByte(); }
				var a:ByteArray = new ByteArray();
				data.setOrigin(a, tagBase + d.position);
				a.writeBytes(d, d.position, start + size - d.position);
				list.push({ flags: flags, key: key, code: a });
				d.position = start + size;
			}
			return list.length ? list : null;
		}

		// ---------------------------------------------------------------- PlaceObject2

		/** Drop the clip event handlers (onClipEvent code) from a PlaceObject2 record. */
		private static function stripClipActions(d:ByteArray):ByteArray
		{
			if (d.length < 3 || (d[0] & 0x80) == 0) return d;
			try
			{
				var flags:int = d[0];
				var br:BitReader = new BitReader(d, 3); // flags + depth
				if (flags & 0x02) br.skipBytes(2);     // character id
				if (flags & 0x04) br.skipMatrix();
				if (flags & 0x08) br.skipCxformAlpha();
				if (flags & 0x10) br.skipBytes(2);     // ratio
				if (flags & 0x20) br.skipString();     // name
				if (flags & 0x40) br.skipBytes(2);     // clip depth
				var cut:int = br.bytePos;
				if (cut > d.length) return d;
				var out:ByteArray = new ByteArray();
				out.endian = Endian.LITTLE_ENDIAN;
				out.writeBytes(d, 0, cut);
				out[0] = flags & 0x7F;
				return out;
			}
			catch (e:Error) {}
			return d;
		}

		// ---------------------------------------------------------------- helpers

		private static function writeTag(out:ByteArray, code:int, data:ByteArray):void
		{
			var len:uint = data ? data.length : 0;
			if (len < 0x3F)
			{
				out.writeShort((code << 6) | len);
			}
			else
			{
				out.writeShort((code << 6) | 0x3F);
				out.writeUnsignedInt(len);
			}
			if (len > 0) out.writeBytes(data, 0, len);
		}

		private static function bytesOf(a:Array):ByteArray
		{
			var b:ByteArray = new ByteArray();
			for each (var v:int in a) b.writeByte(v);
			return b;
		}
	}
}

import flash.utils.ByteArray;

/** Bit-level reader for MATRIX / CXFORM records. */
class BitReader
{
	private var b:ByteArray;
	private var bit:int; // absolute bit position

	public function BitReader(b:ByteArray, bytePos:int)
	{
		this.b = b;
		bit = bytePos * 8;
	}

	public function get bytePos():int
	{
		return Math.ceil(bit / 8);
	}

	private function align():void
	{
		bit = Math.ceil(bit / 8) * 8;
	}

	public function bits(n:int):uint
	{
		var v:uint = 0;
		for (var i:int = 0; i < n; i++)
		{
			var p:int = bit + i;
			if ((p >> 3) >= b.length) throw new Error("eof");
			v = (v << 1) | ((b[p >> 3] >> (7 - (p & 7))) & 1);
		}
		bit += n;
		return v;
	}

	public function skipBytes(n:int):void
	{
		align();
		bit += n * 8;
	}

	public function skipString():void
	{
		align();
		var p:int = bit >> 3;
		while (p < b.length && b[p] != 0) p++;
		bit = (p + 1) * 8;
	}

	public function skipMatrix():void
	{
		align();
		if (bits(1)) { var ns:int = bits(5); bits(ns); bits(ns); }
		if (bits(1)) { var nr:int = bits(5); bits(nr); bits(nr); }
		var nt:int = bits(5);
		bits(nt);
		bits(nt);
		align();
	}

	public function skipRect():void
	{
		align();
		var n:int = bits(5);
		bits(n); bits(n); bits(n); bits(n);
		align();
	}

	/** FILTERLIST of PlaceObject3 */
	public function skipFilters():void
	{
		align();
		var count:int = bits(8);
		for (var i:int = 0; i < count; i++)
		{
			var id:int = bits(8);
			switch (id)
			{
				case 0: skipBytes(23); break;          // drop shadow
				case 1: skipBytes(9); break;           // blur
				case 2: skipBytes(15); break;          // glow
				case 3: skipBytes(27); break;          // bevel
				case 4: case 7:                        // gradient glow / bevel
					var nc:int = bits(8);
					skipBytes(nc * 5 + 19);
					break;
				case 5:                                // convolution
					var mx:int = bits(8), my:int = bits(8);
					skipBytes(8 + mx * my * 4 + 4 + 1);
					break;
				case 6: skipBytes(80); break;          // color matrix
				default: throw new Error("filter");
			}
		}
	}

	public function skipCxformAlpha():void
	{
		align();
		var hasAdd:uint = bits(1);
		var hasMult:uint = bits(1);
		var n:int = bits(4);
		if (hasMult) { bits(n); bits(n); bits(n); bits(n); }
		if (hasAdd) { bits(n); bits(n); bits(n); bits(n); }
		align();
	}
}
