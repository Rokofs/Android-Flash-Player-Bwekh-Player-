package fp.avm1
{
	import flash.utils.ByteArray;
	import flash.utils.Dictionary;
	import flash.utils.Endian;

	/**
	 * Translates AS1/AS2 code blocks (and the functions in them) into AS3 bytecode, so AIR runs
	 * them itself instead of our interpreter reading them action by action.
	 *
	 * Each block becomes a global function fp_cm_<n>(vm:Vm, c:Ctx, code:ByteArray). The AVM1 value
	 * stack is AIR's own operand stack, registers are local variables, jumps are real jumps.
	 * Everything with meaning (variables, members, calls, frames...) goes to Vm.h_* methods,
	 * which do exactly what the interpreter does. Actions without a fast path run one at a time
	 * in the interpreter (Vm.h_op).
	 *
	 * A block is compiled only if it is plain enough: no with/try/throw/for..in, every jump
	 * stays inside the block, the stack has the same depth wherever paths meet, calls have a
	 * known number of arguments. Anything else stays with the interpreter, so a block that
	 * can't be compiled still works exactly as before.
	 */
	public class Compiler
	{
		/** compiled units: { code, start, end } in method order (fp_cm_<index>) */
		public var units:Array = [];
		public var tried:int = 0;
		public var failed:int = 0;
		/** why blocks weren't compiled: reason -> count */
		public var reasons:Object = {};
		/** where compiled code hands over to the interpreter: reason -> count */
		public var bails:Object = {};
		/** units that keep their stack in c.stack */
		public var arrayUnits:int = 0;

		private var version:int;
		private var done:Dictionary = new Dictionary(true); // code -> { start -> true }

		// ----------------------------------------------------------------- ABC constant pools
		private var strings:Array = [];
		private var stringIdx:Object = {};
		private var ints:Array = [];
		private var intIdx:Object = {};
		private var doubles:Array = [];
		private var doubleIdx:Object = {};
		private var namespaces:Array = []; // [kind, string index]
		private var nsIdx:Object = {};
		private var nsSets:Array = [];     // [[ns index]]
		private var multinames:Array = []; // ByteArray of each multiname's data
		private var mnIdx:Object = {};
		private var methodBodies:Array = []; // ByteArray per compiled method

		public var log:Function;
		private var logged:int = 0;
		private var origins:Dictionary;
		private var source:ByteArray;

		/** origins: code block -> its offset in source (the whole SWF), for code that jumps out of its block */
		public function Compiler(version:int, origins:Dictionary = null, source:ByteArray = null)
		{
			this.version = version;
			this.origins = origins;
			this.source = source;
		}

		// ----------------------------------------------------------------- entry points

		/** compile a whole code block (DoAction, clip event...), and the functions inside it */
		public function compileBlock(code:ByteArray):void
		{
			compileUnit(code, 0, code.length, null);
		}

		/** the ABC with all compiled functions (null if nothing was compiled) */
		public function finish():ByteArray
		{
			if (!units.length) return null;
			return writeAbc();
		}

		// ----------------------------------------------------------------- decoding

		private static const STOP:int = -1;
		/** places outside their block that code jumps to: [offset in source, end] */
		private var escapes:Array = [];

		private function fail(why:String):int
		{
			failed++;
			reasons[why] = (reasons[why] | 0) + 1;
			return -1;
		}

		/** fixed stack effects [pops, pushes] of actions run through h_op */
		private static var EFFECT:Object;

		private static function effects():Object
		{
			if (EFFECT) return EFFECT;
			var e:Object = {};
			for each (var z:int in [0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x28, 0x81, 0x83, 0x88, 0x8B, 0x8C]) e[z] = [0, 0];
			for each (var b:int in [0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10, 0x11, 0x13, 0x21, 0x22, 0x29, 0x2B, 0x3A, 0x3F,
				0x47, 0x48, 0x49, 0x4E, 0x54, 0x60, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68]) e[b] = [2, 1];
			for each (var u:int in [0x12, 0x14, 0x18, 0x1C, 0x30, 0x31, 0x32, 0x33, 0x36, 0x37, 0x3B, 0x44, 0x45, 0x4A, 0x4B, 0x50, 0x51])
				e[u] = [1, 1];
			for each (var p:int in [0x17, 0x20, 0x25, 0x26, 0x41, 0x9E, 0x9F]) e[p] = [1, 0];
			e[0x15] = [3, 1]; e[0x35] = [3, 1];
			e[0x1D] = [2, 0]; e[0x3C] = [2, 0]; e[0x69] = [2, 0]; e[0x9A] = [2, 0];
			e[0x23] = [3, 0]; e[0x24] = [3, 0]; e[0x4F] = [3, 0];
			e[0x34] = [0, 1];
			EFFECT = e;
			return e;
		}

		private static const UNSUPPORTED:Object = { 0x27: "startDrag", 0x2A: "throw", 0x2C: "implements", 0x46: "for-in",
			0x55: "for-in", 0x8A: "waitForFrame", 0x8D: "waitForFrame", 0x8F: "try", 0x94: "with" };

		/**
		 * Compile code[start, end). pool: the constant pool known at compile time (null = read
		 * c.pool at run time). Returns the unit's index or -1.
		 */
		private function compileUnit(code:ByteArray, start:int, end:int, pool:Array):int
		{
			var dm:Object = done[code];
			if (!dm) done[code] = dm = {};
			var dk:String = start + "/" + end;
			if (dm[dk] !== undefined) return dm[dk];
			dm[dk] = -1;
			tried++;
			code.endian = Endian.LITTLE_ENDIAN;
			var len:int = code.length;
			if (start < 0 || end > len || start >= end) return fail("range");

			// ---- find every reachable action
			var ins:Object = {};        // pc -> Ins
			var list:Array = [];
			var work:Array = [start];
			var targets:Object = {};    // pc -> true (jump targets)
			var inner:Array = [];       // functions defined here: [start, end]
			var pools:int = 0;
			var firstPool:Array = null;
			var poolAtStart:Boolean = false;
			while (work.length)
			{
				var pc:int = work.pop();
				if (pc >= end) continue;
				if (pc < 0) return fail("negative pc");
				if (ins[pc]) continue;
				var op:int = code[pc];
				var size:int = 1;
				if (op >= 0x80) size = pc + 3 > len ? len - pc : 3 + (code[pc + 1] | (code[pc + 2] << 8));
				var next:int = pc + size;
				var I:Object = { pc: pc, op: op, size: size, next: next, data: pc + 3, target: STOP, depth: -1, consts: null };
				// what we can't translate is left to the interpreter from there on
				var bail:String = null;
				if (next > len) bail = "truncated";
				else if (UNSUPPORTED[op] !== undefined) bail = UNSUPPORTED[op];
				if (bail) { I.bail = bail; ins[pc] = I; list.push(I); continue; }
				if (op == 0x00) { I.next = end; }
				else if (op == 0x99 || op == 0x9D)
				{
					var off:int = code[pc + 3] | (code[pc + 4] << 8);
					if (off >= 0x8000) off -= 0x10000;
					var t:int = next + off;
					if (t < 0 || t > len)
					{
						// out of this code: Flash goes on in the SWF's bytes there (Vm.escape)
						I.escape = t;
						var org:* = origins && source && code != source ? origins[code] : undefined;
						if (org !== undefined && int(org) + t >= 0 && int(org) + t < source.length && t < end)
							escapes.push([int(org) + t, int(org) + end]);
					}
					else
					{
						I.target = t >= end ? end : t;
						if (t < end) { targets[t] = true; work.push(t); }
					}
				}
				else if (op == 0x9B || op == 0x8E)
				{
					var fr:Object = functionRange(code, pc, op);
					if (!fr) { I.bail = "function header"; ins[pc] = I; list.push(I); continue; }
					I.fname = fr.name;
					I.fstart = fr.start;
					I.fend = fr.end;
					next = fr.end;
					I.next = next;
					inner.push(I);
				}
				else if (op == 0x88)
				{
					pools++;
					if (pc == start) { poolAtStart = true; firstPool = readPool(code, pc + 3); }
				}
				else if (op == 0x96)
				{
					I.items = readPush(code, pc + 3, next);
					if (!I.items) { I.bail = "push"; ins[pc] = I; list.push(I); continue; }
				}
				else if (op == 0x87) I.reg = code[pc + 3];
				ins[pc] = I;
				list.push(I);
				if (op != 0x99 && op != 0x3E && op != 0x00) work.push(next);
				else if (op == 0x99 && I.escape !== undefined) {}
			}
			list.sortOn("pc", Array.NUMERIC);
			// one constant pool at the very start: its strings are known while compiling
			var staticPool:Array = pool;
			if (pools > 1 || (pools == 1 && !poolAtStart)) staticPool = null;
			else if (pools == 1) staticPool = firstPool;

			// ---- stack depths (and known numbers, for argument counts)
			var eff:Object = effects();
			var maxDepth:int = 0;
			var maxReg:int = -1;
			var q:Array = [ins[start]];
			if (!ins[start]) return fail("empty");
			ins[start].depth = 0;
			ins[start].consts = [];
			var guard:int = 0;
			// AVM1 code may leave values on the stack (obfuscators even read them back later): if
			// paths meet with different stack heights, the code keeps its stack in c.stack instead
			var mismatch:Boolean = false;
			while (q.length && guard++ < 200000)
			{
				I = q.shift();
				var st:Array = I.consts.concat();
				op = I.op;
				var r:Object = I.bail ? I.bail : stackStep(I, st, eff, staticPool);
				if (r is String)
				{
					I.sbail = r;
					bails[r] = (bails[r] | 0) + 1;
					if (log != null && logged++ < 40) log("compiler: bail " + r + " at " + I.pc + " op " + I.op.toString(16) + " unit " + start + "-" + end + " org " + (origins ? origins[code] : "?"));
					continue;
				}
				if (st.length > maxDepth) maxDepth = st.length;
				if (I.op == 0x87 && I.reg > maxReg) maxReg = I.reg;
				if (I.items) for each (var it:Object in I.items) if (it.k == 1 && it.v > maxReg) maxReg = it.v;
				I.outDepth = st.length;
				var succ:Array = [];
				if (op == 0x99) { if (I.escape === undefined) succ.push(I.target); }
				else if (op == 0x9D)
				{
					if (I.constCond !== true) succ.push(I.next);
					if (I.escape === undefined && I.constCond !== false) succ.push(I.target);
				}
				else if (op != 0x3E && op != 0x00) succ.push(I.next);
				for each (var s:int in succ)
				{
					if (s >= end) continue;
					var N:Object = ins[s];
					if (!N) return fail("lost target");
					if (N.depth < 0)
					{
						N.depth = st.length;
						N.consts = st.concat();
						q.push(N);
					}
					else
					{
						if (N.depth != st.length) { mismatch = true; break; }
						var changed:Boolean = false;
						for (var j:int = 0; j < st.length; j++)
						{
							if (N.consts[j] !== st[j] && N.consts[j] !== null) { N.consts[j] = null; changed = true; }
						}
						if (changed) q.push(N);
					}
				}
				if (mismatch) break;
			}
			if (guard >= 200000) return fail("analysis");
			if (mismatch)
			{
				arrayUnits++;
				maxReg = -1;
				for each (var AI:Object in list)
				{
					AI.depth = 0;
					AI.sbail = null;
					if (AI.op == 0x87 && AI.reg > maxReg) maxReg = AI.reg;
					if (AI.items) for each (var it2:Object in AI.items) if (it2.k == 1 && it2.v > maxReg) maxReg = it2.v;
				}
			}
			for each (var FI:Object in inner)
			{
				if (FI.depth < 0) continue;
				for each (var LI:Object in list)
					if (LI.depth >= 0 && LI.pc > FI.pc && LI.pc < FI.fend) return fail("jump into a function");
			}
			if (maxReg > 250) return fail("registers");

			// ---- the functions defined here are compiled as their own units
			var myIndex:int = units.length;
			units.push({ code: code, start: start, end: end });
			dm[dk] = myIndex;
			methodBodies.push(null);
			var body:ByteArray = mismatch ? emitArray(code, start, end, list, targets, staticPool, maxReg)
				: emit(code, start, end, list, ins, targets, staticPool, maxDepth, maxReg);
			if (!body)
			{
				// (can't happen for a block that passed the checks, but stay safe)
				units[myIndex] = null;
				dm[dk] = -1;
				return fail("emit");
			}
			methodBodies[myIndex] = body;
			bodyInfo[myIndex] = lastInfo;
			for each (var F:Object in inner) if (F.depth >= 0) compileUnit(code, F.fstart, F.fend, staticPool);
			// where the interpreter takes over, it may define more functions further on: find them by
			// reading the rest of the code in order
			var anyBail:Boolean = false;
			for each (var BI:Object in list) if (BI.depth >= 0 && (BI.bail || BI.sbail)) { anyBail = true; break; }
			if (anyBail)
			{
				var lp:int = start;
				var lpool:Array = pools ? null : staticPool;
				while (lp < end && lp < len)
				{
					var lop:int = code[lp];
					if (lop == 0) break;
					var lsz:int = lop >= 0x80 ? (lp + 3 <= len ? 3 + (code[lp + 1] | (code[lp + 2] << 8)) : len) : 1;
					if (lop == 0x9B || lop == 0x8E)
					{
						var lfr:Object = functionRange(code, lp, lop);
						if (!lfr) break;
						compileUnit(code, lfr.start, lfr.end, lpool);
						lp = lfr.end;
						continue;
					}
					lp += lsz;
				}
			}
			while (escapes.length)
			{
				var E:Array = escapes.shift();
				var ei:int = compileUnit(source, E[0], E[1], null);
				if (ei >= 0) units[ei].escape = true;
			}
			return myIndex;
		}

		/** the function an action 0x9B / 0x8E defines: { name, start, end } */
		private function functionRange(code:ByteArray, pc:int, op:int):Object
		{
			try
			{
				code.position = pc + 3;
				var name:String = Vm.readStr(code);
				var n:int = code.readUnsignedShort();
				if (op == 0x9B)
				{
					for (var i:int = 0; i < n; i++) Vm.readStr(code);
				}
				else
				{
					code.readUnsignedByte();
					code.readUnsignedShort();
					for (var j:int = 0; j < n; j++) { code.readUnsignedByte(); Vm.readStr(code); }
				}
				var size:int = code.readUnsignedShort();
				var s:int = code.position;
				if (s + size > code.length) return null;
				return { name: name, start: s, end: s + size };
			}
			catch (e:Error) {}
			return null;
		}

		private function readPool(code:ByteArray, at:int):Array
		{
			code.position = at;
			var n:int = code.readUnsignedShort();
			var res:Array = [];
			for (var i:int = 0; i < n; i++) res.push(Vm.readStr(code));
			return res;
		}

		/** Push items: { k: 0 value | 1 register | 2 pool index, v } */
		private function readPush(code:ByteArray, at:int, next:int):Array
		{
			var res:Array = [];
			code.position = at;
			while (code.position < next)
			{
				var t:int = code.readUnsignedByte();
				switch (t)
				{
					case 0: res.push({ k: 0, v: Vm.readStr(code) }); break;
					case 1: res.push({ k: 0, v: Number(code.readFloat()) }); break;
					case 2: res.push({ k: 0, v: null }); break;
					case 3: res.push({ k: 0, v: undefined }); break;
					case 4: res.push({ k: 1, v: code.readUnsignedByte() }); break;
					case 5: res.push({ k: 0, v: code.readUnsignedByte() != 0 }); break;
					case 6:
						var d:ByteArray = new ByteArray(); d.endian = Endian.LITTLE_ENDIAN;
						d.writeBytes(code, code.position + 4, 4); d.writeBytes(code, code.position, 4); d.position = 0;
						res.push({ k: 0, v: d.readDouble() }); code.position += 8;
						break;
					case 7: res.push({ k: 0, v: Number(code.readInt()) }); break;
					case 8: res.push({ k: 2, v: code.readUnsignedByte() }); break;
					case 9: res.push({ k: 2, v: code.readUnsignedShort() }); break;
					default: return null;
				}
			}
			if (code.position != next) return null;
			return res;
		}

		/** argument count on the stack at depth from the top (a number pushed right there), or -1 */
		private static function known(st:Array, fromTop:int):int
		{
			var i:int = st.length - 1 - fromTop;
			if (i < 0) return -1;
			var v:* = st[i];
			if (!(v is Number)) return -1;
			var n:Number = v;
			if (n < 0 || n > 255 || n != Math.floor(n)) return -1;
			return int(n);
		}

		/**
		 * Apply an action to the abstract stack (numbers we know, null = something else).
		 * Notes on I how it will be compiled. Returns null or why it can't be.
		 */
		private function stackStep(I:Object, st:Array, eff:Object, pool:Array):Object
		{
			var op:int = I.op;
			var n:int;
			switch (op)
			{
				case 0x00: return null;
				case 0x96:
					for each (var it:Object in I.items)
					{
						if (it.k == 0 && (it.v is Number || it.v is Boolean)) st.push(it.v);
						else st.push(null);
					}
					return null;
				case 0x17: if (!st.length) return "pop on empty"; st.pop(); return null;
				case 0x4C: if (!st.length) return "dup on empty"; st.push(st[st.length - 1]); return null;
				case 0x4D: if (st.length < 2) return "swap"; var a:* = st.pop(), b:* = st.pop(); st.push(a); st.push(b); return null;
				case 0x87: if (!st.length) return "store on empty"; return null;
				case 0x99: return null;
				case 0x9D:
				{
					if (!st.length) return "if on empty";
					var cv:* = st.pop();
					// obfuscators branch on constants: only the path really taken counts
					var cc:* = cv is Boolean ? cv : cv is Number ? (cv != 0 && !isNaN(cv)) : null;
					if (!I.seenIf) { I.seenIf = true; I.constCond = cc; }
					else if (I.constCond !== cc) I.constCond = null;
					return null;
				}
				case 0x12: // Not
				{
					if (!st.length) return "stack too short";
					var nv:* = st.pop();
					if (nv is Boolean || nv is Number)
					{
						var nb:Boolean = nv is Boolean ? !nv : !(nv != 0 && !isNaN(nv));
						st.push(version >= 5 ? nb : (nb ? 1 : 0));
					}
					else st.push(null);
					I.nIn = 1; I.nOut = 1; I.opEnd = I.next;
					return null;
				}
				case 0x3E: if (!st.length) st.push(null); st.pop(); return null;
				case 0x9B: case 0x8E:
					I.nIn = 0; I.nOut = I.fname == "" ? 1 : 0; I.opEnd = I.fend;
					if (I.nOut) st.push(null);
					return null;
				case 0x3D: case 0x40: // CallFunction / NewObject: name, n, args
					n = known(st, 1);
					if (n < 0) return "unknown argument count";
					if (st.length < 2 + n) return "stack too short";
					I.nArgs = n;
					st.length -= 2 + n; st.push(null);
					if (op == 0x40) { I.nIn = 2 + n; I.nOut = 1; I.opEnd = I.next; }
					return null;
				case 0x52: case 0x53: // CallMethod / NewMethod: name, object, n, args
					n = known(st, 2);
					if (n < 0) return "unknown argument count";
					if (st.length < 3 + n) return "stack too short";
					I.nArgs = n;
					st.length -= 3 + n; st.push(null);
					if (op == 0x53) { I.nIn = 3 + n; I.nOut = 1; I.opEnd = I.next; }
					return null;
				case 0x42: // InitArray: n, elements
					n = known(st, 0);
					if (n < 0) return "unknown array size";
					if (st.length < 1 + n) return "stack too short";
					I.nIn = 1 + n; I.nOut = 1; I.opEnd = I.next;
					st.length -= 1 + n; st.push(null);
					return null;
				case 0x43: // InitObject: n, pairs
					n = known(st, 0);
					if (n < 0) return "unknown object size";
					if (st.length < 1 + 2 * n) return "stack too short";
					I.nIn = 1 + 2 * n; I.nOut = 1; I.opEnd = I.next;
					st.length -= 1 + 2 * n; st.push(null);
					return null;
			}
			var e:Array = eff[op];
			if (!e) return "action " + op.toString(16);
			if (st.length < e[0]) return "stack too short";
			I.nIn = e[0]; I.nOut = e[1]; I.opEnd = I.next;
			st.length -= e[0];
			for (var k:int = 0; k < e[1]; k++) st.push(null);
			return null;
		}

		// ----------------------------------------------------------------- code generation

		// locals: 0 this, 1 vm, 2 c, 3 code, 4..7 temporaries, 8.. AVM1 registers
		private static const T0:int = 4, T1:int = 5, T2:int = 6, T3:int = 7, REG:int = 8;

		private var out:ByteArray;
		/** positions of branch offsets to fill: { at, from, target pc } */
		private var fixups:Array;
		private var labels:Object;

		private function emit(code:ByteArray, start:int, end:int, list:Array, ins:Object, targets:Object,
			pool:Array, maxDepth:int, maxReg:int):ByteArray
		{
			out = new ByteArray();
			out.endian = Endian.LITTLE_ENDIAN;
			fixups = [];
			labels = {};
			var EXIT:int = end;
			spill = REG + maxReg + 1;

			// registers in, from c.regs (function registers are set up by Vm.callFunction)
			for (var r:int = 0; r <= maxReg; r++)
			{
				u8(0xD2);                     // getlocal2 (c)
				u8(0x66); u30(qn("", "regs")); // getproperty regs
				pushInt(r);
				u8(0x66); u30(mnL());          // getproperty [r]
				setLocal(REG + r);
			}

			for (var i:int = 0; i < list.length; i++)
			{
				var I:Object = list[i];
				if (I.depth < 0) continue; // never reached (shouldn't happen)
				if (targets[I.pc]) { labels[I.pc] = out.position; u8(0x09); } // label
				else labels[I.pc] = out.position;
				var op:int = I.op;
				if (I.bail || I.sbail) { resumeAt(I, end, maxReg); continue; }
				switch (op)
				{
					case 0x00: u8(0x47); break;
					case 0x96:
						for each (var it:Object in I.items)
						{
							if (it.k == 1) getLocal(REG + it.v);
							else if (it.k == 2)
							{
								if (pool) pushValue(it.v < pool.length ? pool[it.v] : undefined);
								else
								{
									u8(0xD2); u8(0x66); u30(qn("", "pool"));
									pushInt(it.v);
									u8(0x66); u30(mnL());
								}
							}
							else pushValue(it.v);
						}
						break;
					case 0x17: u8(0x29); break;            // pop
					case 0x4C: u8(0x2A); break;            // dup
					case 0x4D: u8(0x2B); break;            // swap
					case 0x87: u8(0x2A); setLocal(REG + I.reg); break;
					case 0x1C: // GetVariable
						setLocal(T0);
						call("h_getVar", [1, 2, -T0], true);
						break;
					case 0x1D: // SetVariable
						setLocal(T1); setLocal(T0);
						call("h_setVar", [1, 2, -T0, -T1], false);
						break;
					case 0x4E: // GetMember
						setLocal(T1); setLocal(T0);
						call("h_getMember", [1, -T0, -T1], true);
						break;
					case 0x4F: // SetMember
						setLocal(T2); setLocal(T1); setLocal(T0);
						call("h_setMember", [1, -T0, -T1, -T2], false);
						break;
					case 0x3D: // CallFunction
						setLocal(T0); u8(0x29);
						u8(0x56); u30(I.nArgs); setLocal(T1);
						call("h_callFunction", [1, 2, -T0, -T1], true);
						break;
					case 0x52: // CallMethod
						setLocal(T0); setLocal(T1); u8(0x29);
						u8(0x56); u30(I.nArgs); setLocal(T2);
						call("h_callMethod", [1, -T1, -T0, -T2], true);
						break;
					case 0x88: // ConstantPool
						pushInt(I.pc); setLocal(T0);
						call("h_pool", [1, 2, 3, -T0], false);
						break;
					case 0x22: // GetProperty
						setLocal(T1); setLocal(T0);
						call("h_getProp", [1, 2, -T0, -T1], true);
						break;
					case 0x23: // SetProperty
						setLocal(T2); setLocal(T1); setLocal(T0);
						call("h_setProp", [1, 2, -T0, -T1, -T2], false);
						break;
					case 0x47: binary("h_add2"); break;
					case 0x48: binary("h_less2"); break;
					case 0x67: binary("h_greater"); break;
					case 0x49: binary("h_eq2"); break;
					case 0x66: binary("h_strictEq"); break;
					case 0x0D: binary("h_div"); break;
					case 0x12: setLocal(T0); call("h_not", [1, -T0], true); break;
					case 0x0A: case 0x0B: case 0x0C: case 0x3F: // numeric + - * %
						setLocal(T1); setLocal(T0);
						call("h_num", [1, -T0], true);
						call("h_num", [1, -T1], true);
						u8(op == 0x0A ? 0xA0 : op == 0x0B ? 0xA1 : op == 0x0C ? 0xA2 : 0xA4);
						break;
					case 0x50: case 0x51: // increment / decrement
						setLocal(T0);
						call("h_num", [1, -T0], true);
						u8(0x24); u8(1);           // pushbyte 1
						u8(op == 0x50 ? 0xA0 : 0xA1);
						break;
					case 0x9D: // If
						if (I.constCond === false) { u8(0x29); break; }
						if (I.constCond === true && I.escape === undefined)
						{
							u8(0x29);
							edgeTo(I, I.outDepth, I.target, ins, end);
							continue;
						}
						setLocal(T3);
						call("h_bool", [1, -T3], true);
						if (I.escape !== undefined)
						{
							branch(0x12, "x" + I.pc, I.pc); // iffalse: stay
							escapeTo(I, I.depth - 1, end, maxReg);
							labels["x" + I.pc] = out.position;
							break;
						}
						if (I.target >= end || I.target <= I.pc || extra(I.outDepth, I.target, ins, end) > 0)
						{
							branch(0x12, "x" + I.pc, I.pc); // iffalse: stay
							edgeTo(I, I.outDepth, I.target, ins, end);
							labels["x" + I.pc] = out.position;
						}
						else branch(0x11, I.target, I.pc); // iftrue
						break;
					case 0x99: // Jump
						if (I.escape !== undefined) { escapeTo(I, I.depth, end, maxReg); break; }
						edgeTo(I, I.outDepth, I.target, ins, end);
						break;
					case 0x3E: // Return
						if (I.depth == 0) u8(0x21);
						setLocal(T0);
						call("h_return", [1, 2, -T0], false);
						u8(0x47); // returnvoid
						break;
					default:
						generic(I);
				}
				// falls through to an action that isn't the next one written: jump there
				if (op != 0x99 && op != 0x3E && op != 0x00 && !(op == 0x9D && I.constCond === true && I.escape === undefined))
				{
					var nx:Object = i + 1 < list.length ? list[i + 1] : null;
					if (I.next >= end) u8(0x47);
					else if (!nx || nx.pc != I.next || extra(I.outDepth, I.next, ins, end) > 0) edgeTo(I, I.outDepth, I.next, ins, end);
				}
			}
			labels[EXIT] = out.position;
			u8(0x09);
			u8(0x47); // returnvoid
			for each (var f:Object in fixups)
			{
				var to:* = labels[f.target];
				if (to === undefined) return null;
				var rel:int = int(to) - f.from;
				out.position = f.at;
				out.writeByte(rel & 0xFF); out.writeByte((rel >> 8) & 0xFF); out.writeByte((rel >> 16) & 0xFF);
			}
			out.position = out.length;

			lastInfo = { maxStack: maxDepth + 12, locals: spill + maxDepth + 1 };
			return out;
		}

		private var lastInfo:Object;

		// ------------------------------------------------- stack in c.stack (unbalanced code)

		private static const ST:int = 7;

		/** actions done by a Vm.a_* helper working on the stack array */
		private static const AHELP:Object = { 0x1C: "a_getVar", 0x1D: "a_setVar", 0x4E: "a_getMember", 0x4F: "a_setMember",
			0x47: "a_add2", 0x48: "a_less2", 0x67: "a_greater", 0x49: "a_eq2", 0x66: "a_strictEq", 0x12: "a_not",
			0x0A: "a_add", 0x0B: "a_sub", 0x0C: "a_mul", 0x3F: "a_mod", 0x0D: "a_div", 0x50: "a_inc", 0x51: "a_dec",
			0x0E: "a_equals", 0x4C: "a_dup", 0x4D: "a_swap", 0x22: "a_getProp", 0x23: "a_setProp", 0x52: "a_callMethod",
			0x3D: "a_callFunction" };
		/** helpers that need c rather than the stack */
		private static const AHELP_C:Object = { 0x1C: 1, 0x1D: 1, 0x22: 1, 0x23: 1, 0x3D: 1 };

		private function emitArray(code:ByteArray, start:int, end:int, list:Array, targets:Object, pool:Array, maxReg:int):ByteArray
		{
			out = new ByteArray();
			out.endian = Endian.LITTLE_ENDIAN;
			fixups = [];
			labels = {};
			var EXIT:int = end;
			for (var r:int = 0; r <= maxReg; r++)
			{
				u8(0xD2);
				u8(0x66); u30(qn("", "regs"));
				pushInt(r);
				u8(0x66); u30(mnL());
				setLocal(REG + r);
			}
			u8(0xD2); u8(0x66); u30(qn("", "stack")); setLocal(ST);
			for (var i:int = 0; i < list.length; i++)
			{
				var I:Object = list[i];
				labels[I.pc] = out.position;
				u8(0x09);
				var op:int = I.op;
				if (I.bail)
				{
					flushRegs(maxReg);
					getLocal(1); getLocal(2); getLocal(3); pushInt(I.pc); pushInt(end);
					u8(0x4F); u30(qn("", "a_resume")); u30(4);
					u8(0x47);
					continue;
				}
				var falls:Boolean = true;
				switch (op)
				{
					case 0x00: u8(0x47); falls = false; break;
					case 0x96:
						for each (var it:Object in I.items)
						{
							getLocal(ST);
							if (it.k == 1) getLocal(REG + it.v);
							else if (it.k == 2)
							{
								if (pool) pushValue(it.v < pool.length ? pool[it.v] : undefined);
								else { u8(0xD2); u8(0x66); u30(qn("", "pool")); pushInt(it.v); u8(0x66); u30(mnL()); }
							}
							else pushValue(it.v);
							u8(0x4F); u30(qn("", "push")); u30(1);
						}
						break;
					case 0x17: getLocal(ST); u8(0x4F); u30(qn("", "pop")); u30(0); break;
					case 0x87:
						getLocal(1); getLocal(ST); u8(0x46); u30(qn("", "a_top")); u30(1);
						setLocal(REG + I.reg);
						break;
					case 0x88:
						getLocal(1); getLocal(2); getLocal(3); pushInt(I.pc);
						u8(0x4F); u30(qn("", "h_pool")); u30(3);
						break;
					case 0x3E:
						getLocal(1); getLocal(2); u8(0x4F); u30(qn("", "a_return")); u30(1);
						u8(0x47); falls = false;
						break;
					case 0x99:
						falls = false;
						if (I.escape !== undefined) { escapeA(I, end, maxReg); break; }
						if (I.target != EXIT && I.target <= I.pc) call("h_loop", [1], false);
						if (I.target >= end) u8(0x47); else jumpTo(I.target, I.pc);
						break;
					case 0x9D:
						getLocal(1); getLocal(ST); u8(0x46); u30(qn("", "a_if")); u30(1);
						if (I.escape !== undefined || I.target >= end || I.target <= I.pc)
						{
							branch(0x12, "x" + I.pc, I.pc);
							if (I.escape !== undefined) escapeA(I, end, maxReg);
							else if (I.target >= end) u8(0x47);
							else { call("h_loop", [1], false); jumpTo(I.target, I.pc); }
							labels["x" + I.pc] = out.position;
						}
						else branch(0x11, I.target, I.pc);
						break;
					default:
						var hn:String = AHELP[op];
						if (hn)
						{
							getLocal(1);
							getLocal(AHELP_C[op] ? 2 : ST);
							u8(0x4F); u30(qn("", hn)); u30(1);
						}
						else
						{
							getLocal(1); getLocal(2); getLocal(3); pushInt(I.pc); pushInt(I.op == 0x9B || I.op == 0x8E ? I.fend : I.next);
							u8(0x4F); u30(qn("", "a_op")); u30(4);
						}
				}
				if (falls)
				{
					var nx:Object = i + 1 < list.length ? list[i + 1] : null;
					if (I.next >= end) u8(0x47);
					else if (!nx || nx.pc != I.next) jumpTo(I.next, I.pc);
				}
			}
			labels[EXIT] = out.position;
			u8(0x09);
			u8(0x47);
			for each (var f:Object in fixups)
			{
				var to:* = labels[f.target];
				if (to === undefined) return null;
				var rel:int = int(to) - f.from;
				out.position = f.at;
				out.writeByte(rel & 0xFF); out.writeByte((rel >> 8) & 0xFF); out.writeByte((rel >> 16) & 0xFF);
			}
			out.position = out.length;
			lastInfo = { maxStack: 8, locals: REG + maxReg + 1 };
			return out;
		}

		private function escapeA(I:Object, end:int, maxReg:int):void
		{
			flushRegs(maxReg);
			getLocal(1); getLocal(2); getLocal(3); pushInt(I.escape); pushInt(end);
			u8(0x4F); u30(qn("", "a_escape")); u30(4);
			u8(0x47);
		}

		/** values to drop going from depth to the action at pc */
		private function extra(depth:int, pc:int, ins:Object, end:int):int
		{
			if (pc >= end) return 0;
			var N:Object = ins[pc];
			return N && N.depth >= 0 ? depth - N.depth : 0;
		}

		/** go to pc (end: return), dropping the bottom values the code there doesn't expect */
		private function edgeTo(I:Object, depth:int, pc:int, ins:Object, end:int):void
		{
			if (pc >= end) { u8(0x47); return; }
			var k:int = extra(depth, pc, ins, end);
			if (k > 0)
			{
				var keep:int = depth - k;
				for (var a:int = 0; a < keep; a++) setLocal(spill + a);
				for (var b:int = 0; b < k; b++) u8(0x29);
				for (a = keep - 1; a >= 0; a--) getLocal(spill + a);
			}
			if (pc <= I.pc) call("h_loop", [1], false);
			jumpTo(pc, I.pc);
		}

		/** first local for values set aside by edgeTo */
		private var spill:int;

		/** hand over to the interpreter at this action: registers and stack to c, Vm.h_resume, done */
		private function resumeAt(I:Object, end:int, maxReg:int):void
		{
			flushRegs(maxReg);
			u8(0x56); u30(I.depth);
			setLocal(T0);
			getLocal(1); getLocal(2); getLocal(3);
			pushInt(I.pc); pushInt(end);
			getLocal(T0);
			u8(0x4F); u30(qn("", "h_resume")); u30(5);
			u8(0x47);
		}

		private function flushRegs(maxReg:int):void
		{
			for (var r:int = 0; r <= maxReg; r++)
			{
				u8(0xD2);
				u8(0x66); u30(qn("", "regs"));
				pushInt(r);
				getLocal(REG + r);
				u8(0x61); u30(mnL()); // setproperty [r]
			}
		}

		/** jump out of the block: registers back to c.regs, the stack to c.stack, Vm.h_escape, done */
		private function escapeTo(I:Object, depth:int, end:int, maxReg:int):void
		{
			flushRegs(maxReg);
			u8(0x56); u30(depth);
			setLocal(T0);
			getLocal(1); getLocal(2); getLocal(3);
			pushInt(I.escape); pushInt(end);
			getLocal(T0);
			u8(0x4F); u30(qn("", "h_escape")); u30(5);
			u8(0x47);
		}

		private function binary(name:String):void
		{
			setLocal(T1); setLocal(T0);
			call(name, [1, -T0, -T1], true);
		}

		/** run one action through the interpreter (Vm.h_op) */
		private function generic(I:Object):void
		{
			u8(0x56); u30(I.nIn);   // newarray nIn (bottom first)
			setLocal(T0);
			getLocal(1); getLocal(2); getLocal(3);
			pushInt(I.pc); pushInt(I.opEnd);
			getLocal(T0);
			u8(0x46); u30(qn("", "h_op")); u30(5); // callproperty
			if (I.nOut == 0) { u8(0x29); return; }
			setLocal(T0);
			for (var k:int = 0; k < I.nOut; k++)
			{
				getLocal(T0);
				pushInt(k);
				u8(0x66); u30(mnL());
			}
		}

		/** vm.name(args...): args are locals (negative) or 1/2/3 for vm/c/code */
		private function call(name:String, args:Array, result:Boolean):void
		{
			for each (var a:int in args) getLocal(a < 0 ? -a : a);
			u8(result ? 0x46 : 0x4F);
			u30(qn("", name));
			u30(args.length - 1);
		}

		private function jumpTo(target:int, from:int):void
		{
			branch(0x10, target, from);
		}

		private function branch(op:int, target:*, from:int):void
		{
			u8(op);
			var at:int = out.position;
			u8(0); u8(0); u8(0);
			fixups.push({ at: at, from: out.position, target: target });
		}

		private function getLocal(i:int):void
		{
			if (i <= 3) u8(0xD0 + i);
			else { u8(0x62); u30(i); }
		}

		private function setLocal(i:int):void
		{
			if (i <= 3) u8(0xD4 + i);
			else { u8(0x63); u30(i); }
		}

		private function pushInt(v:int):void
		{
			if (v >= -128 && v <= 127) { u8(0x24); u8(v & 0xFF); }
			else if (v >= 0 && v < 0x8000) { u8(0x25); u30(v); }
			else { u8(0x2D); u30(intConst(v)); }
		}

		private function pushValue(v:*):void
		{
			if (v === undefined) u8(0x21);
			else if (v === null) u8(0x20);
			else if (v === true) u8(0x26);
			else if (v === false) u8(0x27);
			else if (v is String) { u8(0x2C); u30(str(v)); }
			else if (v is Number)
			{
				var n:Number = v;
				// (an int push would make an int, which compares differently from Number in
				//  the helpers only by type: Numbers are what the interpreter uses)
				u8(0x2F); u30(dbl(n));
			}
			else u8(0x21);
		}

		private function u8(v:int):void { out.writeByte(v); }

		private function u30(v:uint):void { writeU30(out, v); }

		private static function writeU30(b:ByteArray, v:uint):void
		{
			do
			{
				var x:int = v & 0x7F;
				v >>>= 7;
				if (v) x |= 0x80;
				b.writeByte(x);
			}
			while (v);
		}

		// ----------------------------------------------------------------- constant pools

		private function str(s:String):int
		{
			var k:String = "s" + s;
			if (stringIdx[k] !== undefined) return stringIdx[k];
			strings.push(s);
			stringIdx[k] = strings.length;
			return strings.length;
		}

		private function intConst(v:int):int
		{
			var k:String = String(v);
			if (intIdx[k] !== undefined) return intIdx[k];
			ints.push(v);
			intIdx[k] = ints.length;
			return ints.length;
		}

		private function dbl(v:Number):int
		{
			var k:String = isNaN(v) ? "NaN" : (v == 0 && 1 / v < 0 ? "-0" : String(v));
			if (doubleIdx[k] !== undefined) return doubleIdx[k];
			doubles.push(v);
			doubleIdx[k] = doubles.length;
			return doubles.length;
		}

		private function nsPkg(name:String):int
		{
			var k:String = "p" + name;
			if (nsIdx[k] !== undefined) return nsIdx[k];
			namespaces.push([0x16, str(name)]);
			nsIdx[k] = namespaces.length;
			return namespaces.length;
		}

		private function qn(pkg:String, name:String):int
		{
			var k:String = "q" + pkg + ":" + name;
			if (mnIdx[k] !== undefined) return mnIdx[k];
			var b:ByteArray = new ByteArray();
			b.writeByte(0x07);
			writeU30(b, nsPkg(pkg));
			writeU30(b, str(name));
			multinames.push(b);
			mnIdx[k] = multinames.length;
			return multinames.length;
		}

		/** MultinameL in the public namespace: a[i] */
		private function mnL():int
		{
			if (mnIdx["L"] !== undefined) return mnIdx["L"];
			if (!nsSets.length) nsSets.push([nsPkg("")]);
			var b:ByteArray = new ByteArray();
			b.writeByte(0x1B);
			writeU30(b, 1);
			multinames.push(b);
			mnIdx["L"] = multinames.length;
			return multinames.length;
		}

		// ----------------------------------------------------------------- the ABC file

		private function writeAbc():ByteArray
		{
			// names the methods' parameter types use
			var tVm:int = qn("fp.avm1", "Vm");
			var tCtx:int = qn("fp.avm1", "Ctx");
			var tBytes:int = qn("flash.utils", "ByteArray");
			var traitNames:Array = [];
			for (var i:int = 0; i < units.length; i++) traitNames.push(units[i] ? qn("", "fp_cm_" + i) : 0);
			mnL();

			var b:ByteArray = new ByteArray();
			b.endian = Endian.LITTLE_ENDIAN;
			b.writeShort(16); // minor
			b.writeShort(46); // major
			// ints
			writeU30(b, ints.length ? ints.length + 1 : 0);
			for each (var iv:int in ints) writeU30(b, uint(iv)); // (s32 written as u30 of its bits)
			// uints
			writeU30(b, 0);
			// doubles
			writeU30(b, doubles.length ? doubles.length + 1 : 0);
			for each (var dv:Number in doubles) b.writeDouble(dv);
			// strings
			writeU30(b, strings.length + 1);
			for each (var s:String in strings)
			{
				var sb:ByteArray = new ByteArray();
				sb.writeUTFBytes(s);
				writeU30(b, sb.length);
				b.writeBytes(sb);
			}
			// namespaces
			writeU30(b, namespaces.length + 1);
			for each (var ns:Array in namespaces) { b.writeByte(ns[0]); writeU30(b, ns[1]); }
			// namespace sets
			writeU30(b, nsSets.length ? nsSets.length + 1 : 0);
			for each (var set:Array in nsSets)
			{
				writeU30(b, set.length);
				for each (var nsi:int in set) writeU30(b, nsi);
			}
			// multinames
			writeU30(b, multinames.length + 1);
			for each (var mb:ByteArray in multinames) b.writeBytes(mb);

			// methods: one per unit, then the script initializer
			var count:int = units.length + 1;
			writeU30(b, count);
			for (i = 0; i < units.length; i++)
			{
				writeU30(b, 3);       // params
				writeU30(b, 0);       // returns *
				writeU30(b, tVm);
				writeU30(b, tCtx);
				writeU30(b, tBytes);
				writeU30(b, 0);       // name
				b.writeByte(0);       // flags
			}
			writeU30(b, 0); writeU30(b, 0); writeU30(b, 0); b.writeByte(0); // script init
			// metadata, classes
			writeU30(b, 0);
			writeU30(b, 0);
			// one script with a function trait per unit
			writeU30(b, 1);
			writeU30(b, units.length); // init method
			var tc:int = 0;
			for (i = 0; i < units.length; i++) if (units[i]) tc++;
			writeU30(b, tc);
			for (i = 0; i < units.length; i++)
			{
				if (!units[i]) continue;
				writeU30(b, traitNames[i]);
				b.writeByte(1);       // Trait_Method
				writeU30(b, 0);       // disp_id
				writeU30(b, i);       // method
			}
			// method bodies
			var nb:int = 1;
			for (i = 0; i < units.length; i++) if (units[i] && methodBodies[i]) nb++;
			writeU30(b, nb);
			for (i = 0; i < units.length; i++)
			{
				if (!units[i] || !methodBodies[i]) continue;
				var body:Object = bodyInfo[i];
				writeU30(b, i);
				writeU30(b, body.maxStack);
				writeU30(b, body.locals);
				writeU30(b, 0);       // init scope depth
				writeU30(b, 1);       // max scope depth
				var code:ByteArray = methodBodies[i];
				writeU30(b, code.length);
				b.writeBytes(code);
				writeU30(b, 0);       // exceptions
				writeU30(b, 0);       // traits
			}
			// script init: getlocal0, pushscope, returnvoid
			writeU30(b, units.length);
			writeU30(b, 1); writeU30(b, 1); writeU30(b, 0); writeU30(b, 1);
			writeU30(b, 3); b.writeByte(0xD0); b.writeByte(0x30); b.writeByte(0x47);
			writeU30(b, 0); writeU30(b, 0);
			b.position = 0;
			return b;
		}

		/** per unit: { maxStack, locals } */
		private var bodyInfo:Object = {};
	}
}
