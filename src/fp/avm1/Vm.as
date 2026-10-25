package fp.avm1
{
	import flash.display.DisplayObject;
	import flash.display.Loader;
	import flash.events.Event;
	import flash.events.IOErrorEvent;
	import flash.system.ApplicationDomain;
	import flash.system.LoaderContext;
	import flash.display.MovieClip;
	import flash.media.SoundMixer;
	import flash.utils.ByteArray;
	import flash.display.DisplayObjectContainer;
	import flash.utils.Dictionary;
	import flash.utils.Endian;
	import flash.utils.getTimer;
	import flash.utils.getQualifiedClassName;

	/**
	 * A small ActionScript 1/2 virtual machine (AVM1) for AIR, where Adobe left AVM1 out.
	 * Modelled on how Flash Player / Ruffle behave. This class: values, conversions, members,
	 * variables and the bytecode interpreter. Display objects: VmDisplay. Built-ins: VmLib.
	 */
	public class Vm
	{
		public var data:Avm1Data;
		public var version:int;
		public var log:Function;
		public var debug:Boolean = false;
		/** how many detailed lines debug mode writes (the log stays small) */
		public var debugLimit:int = 300;

		public var global:AObject;
		public var objectProto:AObject;
		public var functionProto:AObject;
		public var clipProto:AObject;
		public var buttonProto:AObject;
		public var textProto:AObject;
		public var stringProto:AObject;
		public var numberProto:AObject;
		public var booleanProto:AObject;
		public var arrayProto:AObject;
		public var dateProto:AObject;
		public var soundProto:AObject;
		public var colorProto:AObject;

		public var display:VmDisplay;
		public var lib:VmLib;

		/** registered classes: lower-case linkage name -> constructor */
		public var registered:Object = {};

		/** set by getMember: the object a member was found on (for super) */
		public var lastHome:AObject;

		private var callDepth:int = 0;
		private var budget:int = 0;
		/** test builds: instructions run per code block / per opcode (null = off) */
		public var profile:Dictionary;
		public var profileOps:Object = {};
		public var execMs:int = 0;
		/** instructions run (test builds read it for the performance log) */
		public var instrCount:int = 0;
		/** test builds: count execMs (time in the game's code) */
		public var measure:Boolean = false;
		public var profileRuns:Dictionary = new Dictionary();
		private var runStart:int = 0;
		/** debug: the last variable / member that came out undefined */
		/** debug: the last name that wasn't found (kept raw; made into text only when shown) */
		private var missKind:int = 0;
		private var missName:*;
		private var missObj:*;

		private function kidsInfo(c:AClip):String
		{
			try
			{
				var dc:DisplayObjectContainer = c.d as DisplayObjectContainer;
				if (!dc) return "";
				var names:Array = [];
				for (var i:int = 0; i < dc.numChildren; i++) names.push(dc.getChildAt(i).name);
				return " kids[" + names.join(",") + "]";
			}
			catch (e:Error) {}
			return "";
		}

		private function get lastMissing():String
		{
			if (missKind == 1) return "var " + missName + " in " + (missObj is AClip ? display.targetPath(missObj, true) : "?");
			if (missKind == 2) return "member " + toStr(missName) + " of " + (missObj is AClip ? display.targetPath(missObj, true) + " #" + (missObj as AClip).spriteId : typeOf(missObj));
			return "";
		}
		/** instructions one handler may run before it's stopped as an endless loop */
		public var maxSteps:int = 3000000;
		private var errors:int = 0;

		public function Vm(data:Avm1Data, log:Function)
		{
			this.data = data;
			self = this;
			this.version = data.version;
			stringVersion = data.version;
			this.log = log != null ? log : function(s:String):void {};
			objectProto = new AObject(null);
			functionProto = new AObject(objectProto);
			global = new AObject(objectProto);
			lib = new VmLib(this);
			display = new VmDisplay(this);
			lib.setup();
			if (compileCode) try { startCompiler(); } catch (ce:Error) { log("avm1: compiler " + ce); }
		}

		// ================================================================= keys & conversions

		/** property key: SWF 6 and older are case-insensitive */
		public function key(name:String):String
		{
			return version < 7 ? name.toLowerCase() : name;
		}

		public function isFunc(v:*):Boolean
		{
			return v is AFunction || v is ANative;
		}

		public function toNumber(v:*):Number
		{
			if (v is Number) return v;
			if (v === undefined || v === null) return version < 7 ? 0 : NaN;
			if (v is Boolean) return v ? 1 : 0;
			if (v is String)
			{
				var s:String = v;
				if (s == "") return version < 5 ? 0 : NaN;
				var t:String = s.replace(/^[\s]+|[\s]+$/g, "");
				if (t == "") return NaN;
				var n:Number = Number(t);
				return n;
			}
			if (v is AObject || v is Array || v is Date)
			{
				var p:* = toPrimitive(v, "number");
				if (p is AObject || p is Array) return NaN;
				return toNumber(p);
			}
			return Number(v);
		}

		public function toInt32(v:*):int
		{
			var n:Number = toNumber(v);
			if (isNaN(n) || !isFinite(n)) return 0;
			return int(n);
		}

		public function toBoolean(v:*):Boolean
		{
			if (v is Boolean) return v;
			if (v is Number) return !isNaN(v) && v != 0;
			if (v is String)
			{
				if (version >= 7) return v != "";
				var n:Number = toNumber(v);
				return !isNaN(n) && n != 0;
			}
			if (v === undefined || v === null) return false;
			return true;
		}

		public function toStr(v:*):String
		{
			if (v is String) return v;
			if (v === undefined) return version < 7 ? "" : "undefined";
			if (v === null) return "null";
			if (v is Boolean) return v ? "true" : "false";
			if (v is Number) return numToStr(v);
			if (v is AClip) return display.targetPath(v, true);
			if (v is Array)
			{
				var parts:Array = [];
				for each (var e:* in v) parts.push(e === undefined || e === null ? "" : toStr(e));
				return parts.join(",");
			}
			if (v is AObject)
			{
				var p:* = toPrimitive(v, "string");
				if (p is AObject) return v is AFunction || v is ANative ? "[type Function]" : "[object Object]";
				return toStr(p);
			}
			return String(v);
		}

		/** Flash prints numbers with 15 significant digits (0.1 + 0.2 -> "0.3") */
		public function numToStr(n:Number):String
		{
			if (isNaN(n)) return "NaN";
			if (n == Infinity) return "Infinity";
			if (n == -Infinity) return "-Infinity";
			if (n == Math.floor(n) && Math.abs(n) < 1e15) return String(n);
			return String(Number(n.toPrecision(15)));
		}

		/** objects -> primitive through valueOf / toString */
		public function toPrimitive(v:*, hint:String = "number"):*
		{
			if (!(v is AObject) && !(v is Array) && !(v is Date)) return v;
			if (v is Date) return hint == "string" ? (v as Date).toString() : (v as Date).time;
			if (v is Array) return toStr(v);
			var o:AObject = v;
			var order:Array = hint == "string" ? ["toString", "valueOf"] : ["valueOf", "toString"];
			for each (var m:String in order)
			{
				var f:* = getMember(o, m);
				if (isFunc(f))
				{
					var r:* = call(f, o, []);
					if (!(r is AObject)) return r;
				}
			}
			return o;
		}

		public function typeOf(v:*):String
		{
			if (v === undefined) return "undefined";
			if (v === null) return "null";
			if (v is String) return "string";
			if (v is Number) return "number";
			if (v is Boolean) return "boolean";
			if (v is AClip) return (v as AClip).isText ? "object" : "movieclip";
			if (v is AFunction || v is ANative) return "function";
			return "object";
		}

		// ================================================================= equality / comparison

		public function looseEquals(a:*, b:*):Boolean
		{
			if ((a === undefined || a === null) && (b === undefined || b === null)) return true;
			if (a === undefined || a === null || b === undefined || b === null) return false;
			var ta:String = typeOf(a), tb:String = typeOf(b);
			if (ta == tb || (isObj(a) && isObj(b))) return strictEquals(a, b);
			if (a is Number && b is String) return a == toNumber(b);
			if (a is String && b is Number) return toNumber(a) == b;
			if (a is Boolean) return looseEquals(a ? 1 : 0, b);
			if (b is Boolean) return looseEquals(a, b ? 1 : 0);
			if (isObj(a) && (b is Number || b is String)) return looseEquals(toPrimitive(a), b);
			if (isObj(b) && (a is Number || a is String)) return looseEquals(a, toPrimitive(b));
			return false;
		}

		private function isObj(v:*):Boolean
		{
			return v is AObject || v is Array || v is Date;
		}

		public function strictEquals(a:*, b:*):Boolean
		{
			if (a is AClip && b is AClip) return (a as AClip).d == (b as AClip).d;
			return a === b;
		}

		/** a < b; undefined when not comparable (NaN) */
		public function lessThan(a:*, b:*):*
		{
			var pa:* = toPrimitive(a), pb:* = toPrimitive(b);
			if (pa is String && pb is String) return pa < pb;
			var na:Number = toNumber(pa), nb:Number = toNumber(pb);
			if (isNaN(na) || isNaN(nb)) return undefined;
			return na < nb;
		}

		public function add2(a:*, b:*):*
		{
			var pa:* = toPrimitive(a), pb:* = toPrimitive(b);
			if (pa is String || pb is String) return toStr(pa) + toStr(pb);
			return toNumber(pa) + toNumber(pb);
		}

		// ================================================================= objects

		public function newObject():AObject
		{
			return new AObject(objectProto);
		}

		public function nat(name:String, fn:Function, ctor:Function = null):ANative
		{
			var n:ANative = new ANative(functionProto, name, fn, ctor);
			return n;
		}

		/** define a native method / value on an object (key normalized) */
		public function def(o:AObject, name:String, v:*):void
		{
			o.setOwn(key(name), v);
		}

		public function defFn(o:AObject, name:String, fn:Function):ANative
		{
			var n:ANative = nat(name, fn);
			def(o, name, n);
			return n;
		}

		/** member lookup on any value */
		public function getMember(obj:*, name:*):*
		{
			lastHome = null;
			var n:String = name is String ? name : toStr(name);
			if (obj === undefined || obj === null) return undefined;
			if (obj is AClip) return display.getProp(obj, n);
			if (obj is AObject) return objGet(obj, n);
			if (obj is String)
			{
				if (n == "length") return (obj as String).length;
				return protoGet(stringProto, n);
			}
			if (obj is Number) return protoGet(numberProto, n);
			if (obj is Boolean) return protoGet(booleanProto, n);
			if (obj is Array)
			{
				var arr:Array = obj;
				if (n == "length") return arr.length;
				var idx:Number = Number(n);
				if (n != "" && !isNaN(idx) && idx >= 0 && idx == Math.floor(idx)) return arr[int(idx)];
				if (AObject.HOP.call(arr, n)) return arr[n];
				return protoGet(arrayProto, n);
			}
			if (obj is Date) return protoGet(dateProto, n);
			if (obj is ASuper)
			{
				var su:ASuper = obj;
				return su.proto ? objGet(su.proto, n) : undefined;
			}
			try { return obj[n]; } catch (e:Error) {}
			return undefined;
		}

		private function protoGet(p:AObject, n:String):*
		{
			return p ? objGet(p, n) : undefined;
		}

		/** AObject member with prototype chain and addProperty getters */
		public function objGet(o:AObject, n:String):*
		{
			var v:* = objFind(o, n);
			return v === AObject.ABSENT ? undefined : v;
		}

		/** like objGet, but AObject.ABSENT when neither the object nor its prototypes have it */
		public function objFind(o:AObject, n:String):*
		{
			lastHome = null;
			var k:String = key(n);
			if (k == "__proto__") return o.proto;
			var cur:AObject = o;
			var guard:int = 0;
			var absent:Object = AObject.ABSENT;
			while (cur && guard++ < 100)
			{
				if (cur.hasAccessors)
				{
					var acc:Object = cur.getAccessor(k);
					if (acc)
					{
						lastHome = cur;
						return acc["get"] ? call(acc["get"], o, []) : undefined;
					}
				}
				var v:* = cur.lookup(k);
				if (v !== absent)
				{
					lastHome = cur;
					return v;
				}
				cur = cur.proto;
			}
			return absent;
		}

		public function setMember(obj:*, name:*, v:*):void
		{
			var n:String = name is String ? name : toStr(name);
			if (obj === undefined || obj === null) return;
			if (obj is AClip) { display.setProp(obj, n, v); return; }
			if (obj is AObject) { objSet(obj, n, v); return; }
			if (obj is Array)
			{
				var arr:Array = obj;
				if (n == "length") { arr.length = toInt32(v); return; }
				var idx:Number = Number(n);
				if (n != "" && !isNaN(idx) && idx >= 0 && idx == Math.floor(idx)) { arr[int(idx)] = v; return; }
				arr[n] = v;
				return;
			}
			if (obj is ASuper) { setMember((obj as ASuper).thisObj, n, v); return; }
			try { obj[n] = v; } catch (e:Error) {}
		}

		public function objSet(o:AObject, n:String, v:*):void
		{
			var k:String = key(n);
			if (k == "__proto__")
			{
				o.proto = v as AObject;
				return;
			}
			// a setter from addProperty anywhere in the chain
			var cur:AObject = o;
			var guard:int = 0;
			while (cur && guard++ < 100)
			{
				var acc:Object = cur.getAccessor(k);
				if (acc)
				{
					if (acc["set"]) call(acc["set"], o, [v]);
					return;
				}
				if (cur.hasValue(k)) break;
				cur = cur.proto;
			}
			o.setOwn(k, v);
			if (o is AFunction || o is ANative)
			{
				// keep prototype.constructor pointing back
				if (k == key("prototype") && v is AObject && !(v as AObject).hasOwn(key("constructor")))
					(v as AObject).setOwn(key("constructor"), o);
			}
		}

		public function hasProperty(obj:*, n:String):Boolean
		{
			if (obj is AClip) return display.hasProp(obj, n);
			if (obj is AObject)
			{
				var k:String = key(n);
				return (obj as AObject).findHolder(k) != null;
			}
			return false;
		}

		public function deleteMember(obj:*, n:String):Boolean
		{
			if (obj is AObject) return (obj as AObject).deleteOwn(key(n));
			if (obj is Array) { return delete obj[n]; }
			return false;
		}

		/** for..in names */
		public function enumerate(obj:*):Array
		{
			var names:Array = [];
			if (obj is AObject)
			{
				var seen:Object = {};
				var o:AObject = obj;
				var guard:int = 0;
				while (o && guard++ < 100)
				{
					if (o == objectProto || o == clipProto || o == functionProto || o == arrayProto) break;
					for each (var k:String in o.order)
					{
						if (!seen[k] && o.hasValue(k)) { seen[k] = true; names.push(k); }
					}
					o = o.proto;
				}
				if (obj is AClip) names = names.concat(display.childNames(obj));
			}
			else if (obj is Array)
			{
				for (var i:int = (obj as Array).length - 1; i >= 0; i--) names.push(String(i));
				for (var key2:String in obj) if (isNaN(Number(key2))) names.push(key2);
			}
			return names;
		}

		public function instanceOf(v:*, ctor:*):Boolean
		{
			if (!(ctor is AObject)) return false;
			var p:* = getMember(ctor, "prototype");
			if (!(p is AObject)) return false;
			var o:AObject = null;
			if (v is AObject) o = (v as AObject).proto;
			else if (v is Array) o = arrayProto;
			else if (v is String) return false;
			var guard:int = 0;
			while (o && guard++ < 100)
			{
				if (o == p) return true;
				o = o.proto;
			}
			return false;
		}

		// ================================================================= calls

		public function call(f:*, thisObj:*, args:Array, home:AObject = null):*
		{
			if (f is ANative)
			{
				var n:ANative = f;
				return n.fn(thisObj, args);
			}
			if (f is AFunction) return callFunction(f, thisObj, args, home);
			return undefined;
		}

		public function construct(ctor:*, args:Array):*
		{
			if (ctor is ANative)
			{
				var n:ANative = ctor;
				if (n.ctor != null) return n.ctor(args);
				var o0:AObject = newObject();
				var p0:* = getMember(n, "prototype");
				if (p0 is AObject) o0.proto = p0;
				n.fn(o0, args);
				return o0;
			}
			if (ctor is AFunction)
			{
				var f:AFunction = ctor;
				var proto:* = objGet(f, "prototype");
				var o:AObject = new AObject(proto is AObject ? proto : objectProto);
				o.setOwn(key("__constructor__"), f);
				callFunction(f, o, args, proto as AObject);
				return o;
			}
			return undefined;
		}

		/** obj.name(args) — also super calls and Function.call/apply */
		/** debug: method names whose calls are logged with their arguments */
		public var watch:Object = null;

		public function callMethod(obj:*, name:*, args:Array):*
		{
			if (watch && watch["*"] && name is String) warnOnce("method " + name);
			if (watch && name is String && watch[name])
			{
				var parts:Array = [];
				for each (var av:* in args) parts.push(av is AClip ? display.targetPath(av, true) : typeOf(av) + ":" + toStr(av));
				log("avm1: call " + name + " on " + (obj is AClip ? display.targetPath(obj, true) : typeOf(obj)) + " (" + parts.join(", ") + ")");
			}
			if (name === undefined || name === null || name === "")
			{
				// obj(...) or super(...)
				if (obj is ASuper)
				{
					var su:ASuper = obj;
					return call(su.ctor, su.thisObj, args, su.proto);
				}
				return call(obj, undefined, args);
			}
			var n:String = toStr(name);
			if (obj is ASuper)
			{
				var s:ASuper = obj;
				var m:* = s.proto ? objGet(s.proto, n) : undefined;
				var home:AObject = lastHome;
				return call(m, s.thisObj, args, home);
			}
			var f:* = getMember(obj, n);
			var h:AObject = lastHome;
			if (!isFunc(f))
			{
				if (warnedCalls[n]) return undefined; // already told (building the message is slow)
				warnedCalls[n] = true;
				warnOnce("not a function: " + n + " on " + typeOf(obj) + " " + (obj is AClip ? display.targetPath(obj, true) : toStr(obj)) +
					(debug && (obj === undefined || obj === null) ? " (last missing: " + lastMissing + ")" : ""));
				return undefined;
			}
			return call(f, obj, args, h);
		}

		private var warned:Object = {};
		private var warnedCalls:Dictionary = new Dictionary();

		/** an error inside the player's own event handling (not in the game's code) */
		public function handlerError(where:String, e:Error):void
		{
			if (errors++ < 20) log("avm1 error in " + where + ": " + e.message + stackOf(e));
		}

		public function warnOnce(msg:String):void
		{
			if (warned[msg]) return;
			warned[msg] = true;
			log("avm1: " + msg);
		}

		private function callFunction(f:AFunction, thisObj:*, args:Array, home:AObject):*
		{
			if (callDepth > 200)
			{
				warnOnce("call stack too deep");
				return undefined;
			}
			var tSetup:int = hcount ? getTimer() : 0;
			var c:Ctx = new Ctx();
			c.version = f.version;
			c.func = f;
			c.pool = f.pool;
			c.args = args;
			c.home = home;
			c.thisObj = thisObj;
			var base:AClip = f.target;
			// SWF 6+: functions are closures, timeline actions in them act on the clip that defined them
			// (a button's onPress doing gotoAndPlay(2) moves that timeline). SWF 5: on "this".
			if (thisObj is AClip && version < 6) base = thisObj;
			c.target = c.baseTarget = base;
			var act:AObject = new AActivation();
			c.activation = act;
			var sc:Array = f.scope.slice();
			sc[sc.length] = act;
			c.scope = sc;
			if (!f.df2)
			{
				// "this", "arguments" and "super" are found by getVariable when the code asks for them
				for (var i:int = 0; i < f.params.length; i++) act.setOwn(key(f.params[i]), args[i]);
			}
			else
			{
				if (f.regCount > 4) c.regs = new Array(f.regCount); // (else the Ctx's own 4)
				var r:int = 1;
				var fl:int = f.flags;
				// (this / arguments / super not in registers: getVariable finds them when asked)
				if (fl & 0x01) c.regs[r++] = thisObj;                         // this
				if (fl & 0x04) c.regs[r++] = args.concat();                 // arguments
				if (fl & 0x10) c.regs[r++] = makeSuper(c);                  // super
				if (fl & 0x40) c.regs[r++] = display.rootClip;              // _root
				if (fl & 0x80) c.regs[r++] = display.parentOf(base);        // _parent
				if (fl & 0x100) c.regs[r++] = global;                       // _global
				for (var j:int = 0; j < f.params.length; j++)
				{
					var pr:Object = f.params[j];
					if (pr.reg > 0) c.regs[pr.reg] = args[j];
					else act.setOwn(key(pr.name), args[j]);
				}
			}
			if (hcount) { hcount["calls"] = (hcount["calls"] | 0) + 1; hcount["t_callSetup"] = (hcount["t_callSetup"] | 0) + getTimer() - tSetup; }
			callDepth++;
			try
			{
				var cf:Function = compiledOn ? compiledFor(f.code, f.start) : null;
				if (cf != null)
				{
					try { cf(this, c, f.code); }
					catch (ve:Error) { if (!isVerifyError(ve)) throw ve; dropCompiled(f.code, f.start, ve); exec(f.code, f.start, f.end, c); }
				}
				else
				{
					if (debug && compiled[f.code] && !missWarned[f.code + ":" + f.start]) { missWarned[f.code + ":" + f.start] = true; log("avm1: not compiled: function " + f.name + " at " + f.start + "-" + f.end + " of block@" + data.origins[f.code]); }
					exec(f.code, f.start, f.end, c);
				}
			}
			finally
			{
				callDepth--;
			}
			return c.ret;
		}

		private function makeSuper(c:Ctx):ASuper
		{
			var home:AObject = c.home;
			if (!home && c.thisObj is AObject) home = (c.thisObj as AObject).proto;
			if (!home) return null;
			var ctor:* = home.getOwn(key("__constructor__"));
			return new ASuper(c.thisObj, home.proto, ctor);
		}

		// ================================================================= variables

		private static const SPECIAL_VARS:Object = { "this": 1, "_root": 1, "_global": 1, "_parent": 1, "_level0": 1 };

		/** what kind of name a variable name is, worked out once per name */
		private var varKinds:Object = {};
		private static const VK_PLAIN:int = 1, VK_PATH:int = 2, VK_THIS:int = 3, VK_ROOT:int = 4,
			VK_GLOBAL:int = 5, VK_PARENT:int = 6, VK_SUPER:int = 7, VK_ARGUMENTS:int = 8;

		private function varKind(name:String):int
		{
			var k:int = VK_PLAIN;
			var lc:String = name.toLowerCase();
			if (name.indexOf("/") >= 0 || name.indexOf(":") >= 0 || name.indexOf(".") >= 0) k = VK_PATH;
			else if (lc == "this" && (version < 7 || name == "this")) k = VK_THIS;
			else if (lc == "_root" || lc == "_level0") k = VK_ROOT;
			else if (lc == "_global") k = VK_GLOBAL;
			else if (lc == "_parent") k = VK_PARENT;
			else if (lc == "super") k = VK_SUPER;
			else if (lc == "arguments") k = VK_ARGUMENTS;
			varKinds[name] = k;
			return k;
		}

		public function getVariable(c:Ctx, name:String):*
		{
			var kind:int = varKinds[name];
			if (!kind) kind = varKind(name);
			switch (kind)
			{
				case VK_PATH: return getPathVariable(c, name);
				case VK_THIS: return c.thisObj !== undefined ? c.thisObj : c.target;
				case VK_ROOT: return display.rootClip;
				case VK_GLOBAL: return global;
				case VK_PARENT: return display.parentOf(c.target);
			}
			var absent:Object = VmDisplay.ABSENT;
			var absentObj:Object = AObject.ABSENT;
			for (var i:int = c.scope.length - 1; i >= 0; i--)
			{
				var s:* = c.scope[i];
				if (s is AClip)
				{
					// one look instead of "has it?" + "get it"
					lastHome = null;
					var v:* = display.lookupProp(s, name);
					if (v !== absent)
					{
						lastBase = s;
						return v;
					}
				}
				else if (s is AObject)
				{
					var ov:* = objFind(s as AObject, name);
					if (ov !== absentObj)
					{
						lastBase = s;
						return ov;
					}
				}
			}
			if (kind == VK_SUPER) return makeSuper(c);
			if (kind == VK_ARGUMENTS && c.func)
			{
				if (!c.argsCopy) c.argsCopy = c.args ? c.args.concat() : [];
				return c.argsCopy;
			}
			return undefined;
		}

		/** scope object the last plain getVariable found its value on */
		public var lastBase:*;

		public function setVariable(c:Ctx, name:String, v:*):void
		{
			var p:Object = splitPath(name);
			if (p)
			{
				var holder:* = resolvePath(c, p.path);
				if (holder !== undefined && holder !== null) setMember(holder, p.name, v);
				return;
			}
			for (var i:int = c.scope.length - 1; i >= 0; i--)
			{
				var s:* = c.scope[i];
				if (s == global) break;
				if (hasProperty(s, name))
				{
					setMember(s, name, v);
					return;
				}
			}
			// not found: goes on the timeline
			if (c.target) setMember(c.target, name, v);
			else setMember(global, name, v);
		}

		public function defineLocal(c:Ctx, name:String, v:*):void
		{
			if (c.activation) c.activation.setOwn(key(name), v);
			else if (c.target) setMember(c.target, name, v);
		}

		/** "a.b.c" / "/a/b:c" -> {path, name}; null for a plain name */
		public function splitPath(s:String):Object
		{
			var i:int = s.lastIndexOf(":");
			if (i < 0)
			{
				// a dot after the last slash, not part of "..": "a/b.c", "_root.x"
				i = s.lastIndexOf(".");
				if (i <= s.lastIndexOf("/") || (i > 0 && s.charAt(i - 1) == ".")) i = -1;
			}
			if (i < 0) return null;
			return { path: s.substr(0, i), name: s.substr(i + 1) };
		}

		private function getPathVariable(c:Ctx, name:String):*
		{
			var p:Object = splitPath(name);
			if (!p)
			{
				// slash path without variable: "/a/b" is the clip itself
				return resolvePath(c, name);
			}
			var holder:* = resolvePath(c, p.path);
			if (holder === undefined || holder === null) return undefined;
			return getMember(holder, p.name);
		}

		/** "/a/b", "../x", "_root.a", "obj.sub" -> object */
		public function resolvePath(c:Ctx, path:String):*
		{
			if (path == "") return c.target;
			// "/a/b", "../x", "_parent.x", "a.b.c", "../../a.b": slashes first, then dots inside
			var cur:* = null;
			var started:Boolean = false;
			if (path.charAt(0) == "/")
			{
				cur = display.rootClip;
				started = true;
				path = path.substr(1);
			}
			for each (var part:String in path.split("/"))
			{
				if (part == "") continue;
				if (part == "..")
				{
					var from:* = started ? cur : c.target;
					cur = from is AClip ? display.parentOf(from) : undefined;
					started = true;
				}
				else
				{
					for each (var seg:String in part.split("."))
					{
						if (seg == "") continue;
						var owner:* = started ? cur : c.target;
						var kid:AClip = owner is AClip ? display.childClip(owner as AClip, seg) : null;
						if (kid) cur = kid;
						else if (!started) cur = getVariable(c, seg);
						else
						{
							if (cur === undefined || cur === null) return undefined;
							cur = getMember(cur, seg);
						}
						started = true;
					}
				}
				if (started && (cur === undefined || cur === null)) return undefined;
			}
			return started ? cur : c.target;
		}

		/** tellTarget / GetProperty target string -> clip (or null) */
		public function targetClip(c:Ctx, t:*):AClip
		{
			if (t is AClip) return t;
			var s:String = toStr(t);
			if (s == "") return c.target;
			var v:* = resolvePath(c, s);
			return v as AClip;
		}

		// ================================================================= entry points

		/** Run a code block (frame script, event handler) on a clip. */
		private var debugRuns:int = 0;

		/** set when the player closes: no more code runs */
		public var dead:Boolean = false;

		public function runOn(clip:AClip, code:ByteArray, thisObj:* = undefined):void
		{
			if (dead) return;
			if (debug && debugRuns++ < debugLimit) log("avm1: run " + code.length + " bytes on " + (clip ? clip.d + " #" + clip.spriteId + " frame " + ((clip.d as MovieClip) ? (clip.d as MovieClip).currentFrame : 0) : "null"));
			var c:Ctx = new Ctx();
			c.version = version;
			c.target = c.baseTarget = clip;
			c.thisObj = thisObj !== undefined ? thisObj : clip;
			c.scope = [global, clip];
			if (profile) profileRuns[code] = (profileRuns[code] | 0) + 1;
			if ((profile || measure) && runDepth == 0) runStart = getTimer();
			runDepth++;
			var cf:Function = compiledOn ? compiledFor(code, 0) : null;
			if (cf != null)
			{
				try
				{
					guarded(function():void
					{
						try { cf(self, c, code); }
						catch (ve:Error) { if (!isVerifyError(ve)) throw ve; dropCompiled(code, 0, ve); exec(code, 0, code.length, c); }
					});
				}
				finally { afterRun(); }
				return;
			}
			try { guarded(function():void { exec(code, 0, code.length, c); }); }
			finally { afterRun(); }
		}

		/** nesting of runOn / callHandler */
		private var runDepth:int = 0;

		/** the game's code is running (frame code that AIR starts now waits until it ends, as in Flash) */
		public function get running():Boolean { return runDepth > 0; }
		public function get depth():int { return runDepth; }

		private function afterRun():void
		{
			if (--runDepth > 0) return;
			if (profile || measure) execMs += getTimer() - runStart;
			// frames reached by gotos in that code: their scripts run now (Flash order)
			try { display.afterCode(); } catch (e:Error) {}
		}

		/** Call an AS function as an event handler (errors are logged, not thrown). */
		public function callHandler(f:*, thisObj:*, args:Array):*
		{
			var r:*;
			if (dead) return undefined;
			if ((profile || measure) && runDepth == 0) runStart = getTimer();
			runDepth++;
			try { guarded(function():void { r = call(f, thisObj, args); }); }
			finally { afterRun(); }
			return r;
		}

		private function guarded(fn:Function):void
		{
			budget = 0;
			try
			{
				fn();
			}
			catch (t:AThrow)
			{
				warnOnce("uncaught throw: " + toStr(t.value));
			}
			catch (e:Error)
			{
				if (errors++ < 20) log("avm1 error: " + e.message + stackOf(e));
			}
			catch (x:*)
			{
				if (errors++ < 20) log("avm1 error: " + x);
			}
		}

		private static function stackOf(e:Error):String
		{
			var st:* = null;
			try { st = (e as Object).getStackTrace(); } catch (x:Error) {}
			return st ? "\n" + String(st).split("\n").slice(0, 5).join("\n") : "";
		}

		// ================================================================= interpreter

		/** Execute [start, end) of code. Returns where execution stopped (end, or a jump outside). */
		public function exec(code:ByteArray, start:int, end:int, c:Ctx, entry:int = -1):int
		{
			code.endian = Endian.LITTLE_ENDIAN;
			var st:Array = c.stack;
			var pc:int = entry >= 0 ? entry : start;
			var a:*, b:*, n:int, i:int, s:String, obj:*, f:*, args:Array;
			// like Flash: running past the end of the block (or function) ends it; a jump back before
			// its start goes on there (obfuscators hide code in other places)
			while (pc >= 0 && pc < end && !c.returned)
			{
				instrCount++;
				if (++budget > maxSteps) throw new Error("script runs too long (endless loop?) at " + pc + " of " + code.length);
				code.position = pc;
				var op:int = code.readUnsignedByte();
				if (profile) { profile[code] = (profile[code] | 0) + 1; profileOps[op] = (profileOps[op] | 0) + 1; }
				if (op == 0) return end;
				var len:int = 0;
				if (op >= 0x80) len = code.readUnsignedShort();
				var next:int = code.position + len;
				var body:int = code.position;

				switch (op)
				{
					// ---------------------------------------------------- timeline
					case 0x04: display.nextFrame(c.target); break;
					case 0x05: display.prevFrame(c.target); break;
					case 0x06: display.play(c.target); break;
					case 0x07: display.stop(c.target); break;
					case 0x08: break; // toggle quality
					case 0x09: SoundMixer.stopAll(); lib.clearChannels(); break;
					case 0x81: // GotoFrame (0-based)
						display.gotoFrame(c.target, code.readUnsignedShort() + 1, false);
						break;
					case 0x8C: // GoToLabel
						display.gotoFrame(c.target, readStr(code), false);
						break;
					case 0x9F: // GotoFrame2
						var gflags:int = code.readUnsignedByte();
						var bias:int = (gflags & 2) ? code.readUnsignedShort() : 0;
						a = st.pop();
						gotoFrame2(c, a, (gflags & 1) != 0, bias);
						break;
					case 0x8A: break; // WaitForFrame: everything is loaded
					case 0x8D: st.pop(); break; // WaitForFrame2
					case 0x8B: // SetTarget
						s = readStr(code);
						c.target = s == "" ? c.baseTarget : targetClip(withBase(c), s);
						break;
					case 0x20: // SetTarget2
						a = st.pop();
						c.target = (a === "" || a === undefined) ? c.baseTarget : targetClip(withBase(c), a);
						break;
					case 0x9E: // Call (frame)
						callFrame(c, st.pop());
						break;

					// ---------------------------------------------------- stack
					case 0x96: // Push (decoded once per place in the code, see pushOf)
					{
						var pcache:Object = pushCache[code];
						if (!pcache) pushCache[code] = pcache = {};
						var pu:PushOp = pcache[pc];
						if (!pu) pcache[pc] = pu = pushOf(code, body, next);
						var pk:Vector.<int> = pu.kinds;
						var pv:Array = pu.vals;
						var pn:int = pk.length;
						for (i = 0; i < pn; i++)
						{
							var kind:int = pk[i];
							if (kind == 0) st.push(pv[i]);
							else if (kind == 1) st.push(c.regs[pv[i]]);
							else st.push(c.pool[pv[i]]);
						}
						break;
					}
					case 0x17: st.pop(); break;
					case 0x4C: st.push(st[st.length - 1]); break;
					case 0x4D: a = st.pop(); b = st.pop(); st.push(a); st.push(b); break;
					case 0x87: c.regs[code.readUnsignedByte()] = st[st.length - 1]; break;
					case 0x88: // ConstantPool (read once per place in the code)
						c.pool = poolAt(code, pc);
						break;

					// ---------------------------------------------------- arithmetic
					case 0x0A: b = st.pop(); a = st.pop(); st.push(toNumber(a) + toNumber(b)); break;
					case 0x0B: b = st.pop(); a = st.pop(); st.push(toNumber(a) - toNumber(b)); break;
					case 0x0C: b = st.pop(); a = st.pop(); st.push(toNumber(a) * toNumber(b)); break;
					case 0x0D:
						b = st.pop(); a = st.pop();
						var dv:Number = toNumber(b);
						st.push(dv == 0 && version < 5 ? "#ERROR#" : toNumber(a) / dv);
						break;
					case 0x3F: b = st.pop(); a = st.pop(); st.push(toNumber(a) % toNumber(b)); break;
					case 0x47: b = st.pop(); a = st.pop(); st.push(add2(a, b)); break;
					case 0x50: st.push(toNumber(st.pop()) + 1); break;
					case 0x51: st.push(toNumber(st.pop()) - 1); break;
					case 0x60: b = st.pop(); a = st.pop(); st.push(Number(toInt32(a) & toInt32(b))); break;
					case 0x61: b = st.pop(); a = st.pop(); st.push(Number(toInt32(a) | toInt32(b))); break;
					case 0x62: b = st.pop(); a = st.pop(); st.push(Number(toInt32(a) ^ toInt32(b))); break;
					case 0x63: b = st.pop(); a = st.pop(); st.push(Number(toInt32(a) << (toInt32(b) & 31))); break;
					case 0x64: b = st.pop(); a = st.pop(); st.push(Number(toInt32(a) >> (toInt32(b) & 31))); break;
					case 0x65: b = st.pop(); a = st.pop(); st.push(Number(uint(toInt32(a)) >>> (toInt32(b) & 31))); break;
					case 0x18: // ToInteger
						var tn:Number = toNumber(st.pop());
						st.push(isNaN(tn) ? 0 : (tn < 0 ? Math.ceil(tn) : Math.floor(tn)));
						break;
					case 0x4A: st.push(toNumber(st.pop())); break;
					case 0x4B: st.push(toStr(st.pop())); break;
					case 0x30: // RandomNumber
						var mx:int = toInt32(st.pop());
						st.push(mx <= 0 ? 0 : Math.floor(Math.random() * mx));
						break;
					case 0x34: st.push(getTimer() - display.startTime); break;

					// ---------------------------------------------------- comparison / logic
					case 0x0E: b = st.pop(); a = st.pop(); st.push(boolResult(toNumber(a) == toNumber(b))); break;
					case 0x0F: b = st.pop(); a = st.pop(); st.push(boolResult(toNumber(a) < toNumber(b))); break;
					case 0x10: b = st.pop(); a = st.pop(); st.push(boolResult(toBoolean(a) && toBoolean(b))); break;
					case 0x11: b = st.pop(); a = st.pop(); st.push(boolResult(toBoolean(a) || toBoolean(b))); break;
					case 0x12: st.push(boolResult(!toBoolean(st.pop()))); break;
					case 0x49: b = st.pop(); a = st.pop(); st.push(looseEquals(a, b)); break;
					case 0x66: b = st.pop(); a = st.pop(); st.push(strictEquals(a, b)); break;
					case 0x48: b = st.pop(); a = st.pop(); st.push(lessThan(a, b)); break;
					case 0x67: b = st.pop(); a = st.pop(); st.push(lessThan(b, a)); break;
					case 0x13: b = st.pop(); a = st.pop(); st.push(boolResult(toStr(a) == toStr(b))); break;
					case 0x29: b = st.pop(); a = st.pop(); st.push(boolResult(toStr(a) < toStr(b))); break;
					case 0x68: b = st.pop(); a = st.pop(); st.push(boolResult(toStr(a) > toStr(b))); break;

					// ---------------------------------------------------- strings
					case 0x14: case 0x31: st.push(toStr(st.pop()).length); break;
					case 0x21: b = st.pop(); a = st.pop(); st.push(toStr(a) + toStr(b)); break;
					case 0x15: case 0x35: // StringExtract (1-based)
						var cnt:int = toInt32(st.pop());
						var idx:int = toInt32(st.pop());
						s = toStr(st.pop());
						if (idx < 1) idx = 1;
						st.push(cnt < 0 ? s.substr(idx - 1) : s.substr(idx - 1, cnt));
						break;
					case 0x32: case 0x36: s = toStr(st.pop()); st.push(s.length ? s.charCodeAt(0) : 0); break;
					case 0x33: case 0x37: st.push(String.fromCharCode(toInt32(st.pop()))); break;

					// ---------------------------------------------------- variables & members
					case 0x1C: // GetVariable
						s = toStr(st.pop());
						a = getVariable(c, s);
						if (debug && a === undefined)
						{
							missKind = 1; missName = s; missObj = c.target;
							if (watch && watch["?"]) warnOnce("missing " + lastMissing);
						}
						st.push(a);
						break;
					case 0x1D: // SetVariable
						a = st.pop();
						if (watch) { var swn:String = toStr(st[st.length - 1]); if (watch["=" + swn]) log("avm1: set " + swn + " = " + (a is AClip ? display.targetPath(a, true) : typeOf(a) + ":" + toStr(a)) + " in " + (c.target ? display.targetPath(c.target, true) : "?")); }
						setVariable(c, toStr(st.pop()), a);
						break;
					case 0x3C: // DefineLocal
						a = st.pop();
						defineLocal(c, toStr(st.pop()), a);
						break;
					case 0x41: // DefineLocal2
						s = toStr(st.pop());
						if (c.activation) { if (!c.activation.hasOwn(key(s))) c.activation.setOwn(key(s), undefined); }
						else if (c.target && !hasProperty(c.target, s)) setMember(c.target, s, undefined);
						break;
					case 0x4E: // GetMember
						b = st.pop(); a = st.pop();
						obj = getMember(a, b);
						if (watch && watch["." + toStr(b)]) log("avm1: get ." + toStr(b) + " of " + (a is AClip ? display.targetPath(a, true) + kidsInfo(a as AClip) : typeOf(a)) + " = " + (obj is AClip ? display.targetPath(obj, true) : typeOf(obj) + ":" + toStr(obj)));
						if (debug && obj === undefined)
						{
							missKind = 2; missName = b; missObj = a;
							if (watch && watch["?"]) warnOnce("missing " + lastMissing);
						}
						st.push(obj);
						break;
					case 0x4F: // SetMember
						var val:* = st.pop(); b = st.pop(); a = st.pop();
						setMember(a, b, val);
						break;
					case 0x3A: // Delete
						b = st.pop(); a = st.pop();
						st.push(deleteMember(a, toStr(b)));
						break;
					case 0x3B: // Delete2
						s = toStr(st.pop());
						var deleted:Boolean = false;
						for (i = c.scope.length - 1; i >= 0 && !deleted; i--)
						{
							if (hasProperty(c.scope[i], s)) deleted = deleteMember(c.scope[i], s);
						}
						st.push(deleted);
						break;
					case 0x22: // GetProperty
						n = toInt32(st.pop());
						a = targetClip(c, st.pop());
						st.push(a ? display.getIndexed(a, n) : undefined);
						break;
					case 0x23: // SetProperty
						val = st.pop();
						n = toInt32(st.pop());
						a = targetClip(c, st.pop());
						if (a) display.setIndexed(a, n, val);
						break;
					case 0x45: // TargetPath
						a = st.pop();
						st.push(a is AClip ? display.targetPath(a, true) : undefined);
						break;
					case 0x44: st.push(typeOf(st.pop())); break;
					case 0x54: b = st.pop(); a = st.pop(); st.push(instanceOf(a, b)); break;
					case 0x2B: // CastOp
						a = st.pop(); b = st.pop();
						var castOk:Boolean = instanceOf(a, b);
						if (!castOk && debug && a !== undefined && a !== null) warnOnce("cast failed: " + (a is AClip ? display.targetPath(a, true) + " #" + (a as AClip).spriteId : typeOf(a)));
						st.push(castOk ? a : null);
						break;
					case 0x2C: // ImplementsOp
						st.pop();
						n = toInt32(st.pop());
						for (i = 0; i < n; i++) st.pop();
						break;
					case 0x69: // Extends
						var superCls:* = st.pop();
						var subCls:* = st.pop();
						if (subCls is AObject && superCls is AObject)
						{
							var sp:* = getMember(superCls, "prototype");
							var np:AObject = new AObject(sp is AObject ? sp : objectProto);
							np.setOwn(key("__constructor__"), superCls);
							np.setOwn(key("constructor"), subCls);
							(subCls as AObject).setOwn(key("prototype"), np);
						}
						break;
					case 0x46: // Enumerate (variable name)
						obj = getVariable(c, toStr(st.pop()));
						st.push(null);
						for each (s in enumerate(obj)) st.push(s);
						break;
					case 0x55: // Enumerate2
						obj = st.pop();
						st.push(null);
						for each (s in enumerate(obj)) st.push(s);
						break;

					// ---------------------------------------------------- objects
					case 0x40: // NewObject
						s = toStr(st.pop());
						args = popArgs(st);
						f = getVariable(c, s);
						st.push(f !== undefined ? construct(f, args) : lib.constructByName(s, args));
						break;
					case 0x53: // NewMethod
						b = st.pop(); a = st.pop();
						args = popArgs(st);
						f = (b === undefined || b === "" || b === null) ? a : getMember(a, b);
						st.push(construct(f, args));
						break;
					case 0x42: // InitArray
						args = popArgs(st);
						st.push(args);
						break;
					case 0x43: // InitObject
						n = toInt32(st.pop());
						var o:AObject = newObject();
						for (i = 0; i < n; i++)
						{
							a = st.pop();
							b = st.pop();
							objSet(o, toStr(b), a);
						}
						st.push(o);
						break;

					// ---------------------------------------------------- functions
					case 0x3D: // CallFunction
						s = toStr(st.pop());
						if (watch && watch["*"]) warnOnce("function " + s);
						if (watch && watch[s]) log("avm1: callf " + s + " in " + (c.target ? display.targetPath(c.target, true) : "?"));
						args = popArgs(st);
						lastBase = undefined;
						f = getVariable(c, s);
						if (isFunc(f))
						{
							// a function found on a clip or a with() object runs with that as "this"
							var fbase:* = lastBase;
							if (fbase is AActivation || fbase == global) fbase = undefined;
							if (fbase === undefined && f is ANative) fbase = c.target;
							st.push(call(f, fbase, args));
						}
						else st.push(lib.callGlobal(c, s, args));
						break;
					case 0x52: // CallMethod
						b = st.pop(); a = st.pop();
						args = popArgs(st);
						st.push(callMethod(a, b, args));
						break;
					case 0x9B: // DefineFunction
					case 0x8E: // DefineFunction2
						var fn:AFunction = new AFunction(functionProto);
						fn.name = readStr(code);
						n = code.readUnsignedShort();
						if (op == 0x9B)
						{
							for (i = 0; i < n; i++) fn.params.push(readStr(code));
						}
						else
						{
							fn.df2 = true;
							fn.regCount = code.readUnsignedByte();
							fn.flags = code.readUnsignedShort();
							for (i = 0; i < n; i++)
							{
								var reg:int = code.readUnsignedByte();
								fn.params.push({ reg: reg, name: readStr(code) });
							}
						}
						var size:int = code.readUnsignedShort();
						fn.code = code;
						fn.start = code.position;
						fn.end = code.position + size;
						fn.scope = c.scope.concat();
						fn.pool = c.pool;
						fn.target = c.target;
						fn.version = version;
						var fproto:AObject = new AObject(objectProto);
						fproto.setOwn(key("constructor"), fn);
						fn.setOwn(key("prototype"), fproto);
						next = fn.end;
						if (fn.name != "")
						{
							if (c.activation) c.activation.setOwn(key(fn.name), fn);
							else if (c.target) setMember(c.target, fn.name, fn);
						}
						else
						{
							st.push(fn);
						}
						break;
					case 0x3E: // Return
						c.ret = st.pop();
						c.returned = true;
						return end;

					// ---------------------------------------------------- control flow
					case 0x99: // Jump
						next = next + code.readShort();
						if ((next < 0 || next > int(code.length)) && escape(code, next, end, c)) return end;
						break;
					case 0x9D: // If
						var off:int = code.readShort();
						if (toBoolean(st.pop()))
						{
							next = next + off;
							if ((next < 0 || next > int(code.length)) && escape(code, next, end, c)) return end;
						}
						break;
					case 0x94: // With
						var wsize:int = code.readUnsignedShort();
						obj = st.pop();
						var wstart:int = next;
						var wend:int = next + wsize;
						c.scope.push(obj);
						var wstop:int;
						try { wstop = exec(code, wstart, wend, c); }
						finally { c.scope.pop(); }
						next = wstop;
						break;
					case 0x8F: // Try
						next = doTry(code, body, len, c);
						break;
					case 0x2A: // Throw
						throw new AThrow(st.pop());

					// ---------------------------------------------------- misc
					case 0x26: log("trace: " + toStr(st.pop())); break;
					case 0x24: // CloneSprite: depth, target, source
						n = toInt32(st.pop());
						s = toStr(st.pop());
						a = targetClip(c, st.pop());
						if (a) display.duplicate(a, s, n, null);
						break;
					case 0x25: // RemoveSprite
						a = targetClip(c, st.pop());
						if (a) display.remove(a);
						break;
					case 0x27: // StartDrag
						a = targetClip(c, st.pop());
						var lock:Boolean = toBoolean(st.pop());
						var constrain:Boolean = toBoolean(st.pop());
						var rect:Array = null;
						if (constrain)
						{
							var y2:Number = toNumber(st.pop()), x2:Number = toNumber(st.pop());
							var y1:Number = toNumber(st.pop()), x1:Number = toNumber(st.pop());
							rect = [x1, y1, x2, y2];
						}
						if (a) display.startDrag(a, lock, rect);
						break;
					case 0x28: display.stopDrag(); break;
					case 0x83: // GetURL
						var url:String = readStr(code);
						var win:String = readStr(code);
						lib.getURL(c, url, win);
						break;
					case 0x9A: // GetURL2
						var gm:int = code.readUnsignedByte();
						var win2:* = st.pop();
						var url2:* = st.pop();
						lib.getURL2(c, toStr(url2), win2, gm);
						break;
					default:
						warnOnce("unknown action 0x" + op.toString(16));
				}
				pc = next;
			}
			return pc;
		}

		/**
		 * A jump out of the code block (obfuscated games hide code in other tags and jump there):
		 * go on in the SWF's own bytes, as Flash does. True if it ran (the block is then done).
		 */
		private function escape(code:ByteArray, target:int, end:int, c:Ctx):Boolean
		{
			var src:ByteArray = data.source;
			if (!src || code == src) return false;
			var org:* = data.origins[code];
			if (org === undefined) return false;
			var at:int = int(org) + target;
			if (at < 0 || at >= src.length) return false;
			if (target >= end) return false; // past the end: the block is simply over
			if (debug && debugRuns++ < debugLimit) log("avm1: jump out of a block to " + at + " of the file");
			var m:Object = compiledOn && c.stack.length == 0 ? compiled[src] : null;
			var cf:Function = m ? m["e" + at + "/" + (int(org) + end)] as Function : null;
			if (cf != null)
			{
				try { cf(this, c, src); c.returned = true; return true; }
				catch (ve:Error) { if (!isVerifyError(ve)) throw ve; delete m["e" + at + "/" + (int(org) + end)]; }
			}
			exec(src, 0, int(org) + end, c, at);
			c.returned = true; // the code that ran there ended this block
			return true;
		}

		private function boolResult(v:Boolean):*
		{
			return version < 5 ? (v ? 1 : 0) : v;
		}

		private function withBase(c:Ctx):Ctx
		{
			// tellTarget paths are relative to the original timeline
			if (c.target == c.baseTarget) return c;
			var t:Ctx = new Ctx();
			t.scope = c.scope;
			t.target = c.baseTarget;
			t.baseTarget = c.baseTarget;
			t.thisObj = c.thisObj;
			return t;
		}

		// ================================================================= compiled code
		// Code blocks translated to AS3 bytecode (Compiler) call these for everything that isn't
		// plain stack work or a jump. They do exactly what the interpreter does for those actions.

		/** compiled blocks: code -> { start -> Function(vm, ctx, code) } */
		public var compiled:Dictionary = new Dictionary(true);
		/** use compiled code when there is some (off = interpreter only, for comparisons) */
		public var compiledOn:Boolean = true;
		/** translate code to AS3 bytecode when a game starts */
		public static var compileCode:Boolean = true;
		/** debug: only compiled units with index in [lo, hi] are used */
		public static var compileRange:Array;
		private var self:Vm;

		/** blocks translated, blocks tried, ms it took (for the log) */
		public var compileInfo:String = "";
		/** called when the compiled code is in use */
		public var onCompiled:Function;
		private var compileLoader:Loader;

		/** translate the game's code to AS3 bytecode; it is used from the moment AIR has loaded it */
		private function startCompiler():void
		{
			var t0:int = getTimer();
			var cm:Compiler = new Compiler(version, data.origins, data.source);
			cm.log = log;
			for (var k:* in data.origins)
			{
				var b:ByteArray = k as ByteArray;
				if (b) try { cm.compileBlock(b); } catch (e:Error) {}
			}
			var abc:ByteArray = cm.finish();
			var why:Array = [];
			for (var r:String in cm.reasons) why.push(r + " " + cm.reasons[r]);
			var bl:Array = [];
			for (var r2:String in cm.bails) bl.push(r2 + " " + cm.bails[r2]);
			if (bl.length) why.push("interpreter at: " + bl.join(", "));
			if (cm.arrayUnits) why.push(cm.arrayUnits + " with an unbalanced stack");
			compileInfo = cm.units.length + " of " + cm.tried + " blocks, " + (getTimer() - t0) + " ms" + (why.length ? " (not: " + why.join(", ") + ")" : "");
			log("avm1: compiled " + compileInfo);
			if (!abc) return;
			// a tiny SWF holding just that ABC
			var tags:ByteArray = new ByteArray();
			tags.endian = Endian.LITTLE_ENDIAN;
			tags.writeByte(0x00);     // stage RECT with 0-bit fields
			tags.writeShort(24 << 8); // frame rate 24
			tags.writeShort(1);       // one frame
			writeSwfTag(tags, 69, [0x08, 0, 0, 0]);
			var doAbc:ByteArray = new ByteArray();
			doAbc.endian = Endian.LITTLE_ENDIAN;
			doAbc.writeUnsignedInt(0); // flags: run the script now
			doAbc.writeUTFBytes("fpcm"); doAbc.writeByte(0);
			doAbc.writeBytes(abc);
			writeSwfTagBytes(tags, 82, doAbc);
			writeSwfTag(tags, 1, []);
			writeSwfTag(tags, 0, []);
			var swf:ByteArray = new ByteArray();
			swf.endian = Endian.LITTLE_ENDIAN;
			swf.writeUTFBytes("FWS");
			swf.writeByte(10);
			swf.writeUnsignedInt(tags.length + 8);
			swf.writeBytes(tags);
			var units:Array = cm.units;
			var dom:ApplicationDomain = new ApplicationDomain(ApplicationDomain.currentDomain);
			var ctx:LoaderContext = new LoaderContext(false, dom);
			try { ctx["allowCodeImport"] = true; } catch (e1:Error) {}
			compileLoader = new Loader();
			compileLoader.contentLoaderInfo.addEventListener(Event.COMPLETE, function(e:Event):void
			{
				var bound:int = 0;
				for (var i:int = 0; i < units.length; i++)
				{
					var u:Object = units[i];
					if (!u) continue;
					if (compileRange && (i < compileRange[0] || i > compileRange[1])) continue;
					try
					{
						var f:Function = dom.getDefinition("fp_cm_" + i) as Function;
						if (f == null) continue;
						var m:Object = compiled[u.code];
						if (!m) compiled[u.code] = m = {};
						if (u.escape) m["e" + u.start + "/" + u.end] = f;
						else m[u.start] = f;
						bound++;
					}
					catch (e2:Error) {}
				}
				log("avm1: compiled code ready, " + bound + " functions");
				if (onCompiled != null) onCompiled();
			});
			compileLoader.contentLoaderInfo.addEventListener(IOErrorEvent.IO_ERROR, function(e:Event):void { log("avm1: compiled code failed to load " + e); });
			compileLoader.loadBytes(swf, ctx);
		}

		private static function writeSwfTag(out:ByteArray, code:int, bytes:Array):void
		{
			var b:ByteArray = new ByteArray();
			for each (var x:int in bytes) b.writeByte(x);
			writeSwfTagBytes(out, code, b);
		}

		private static function writeSwfTagBytes(out:ByteArray, code:int, b:ByteArray):void
		{
			out.writeShort((code << 6) | 0x3F);
			out.writeUnsignedInt(b.length);
			out.writeBytes(b);
		}

		/** a compiled function failed AIR's check: forget it and run that code in the interpreter */
		private function dropCompiled(code:ByteArray, start:int, e:Error):void
		{
			var m:Object = compiled[code];
			if (m) delete m[start];
			if (warnedCompile++ < 5) log("avm1: compiled code rejected: " + e);
		}
		private var warnedCompile:int = 0;
		private var missWarned:Object = {};

		private static function isVerifyError(e:Error):Boolean
		{
			return getQualifiedClassName(e) == "VerifyError";
		}

		public function compiledFor(code:ByteArray, start:int):Function
		{
			var m:Object = compiled[code];
			return m ? m[start] as Function : null;
		}

		/** debug: calls of compiled-code helpers, and ms spent ("t_" names) */
		public var hcount:Object;

		/** the biggest hcount entries, for the log */
		public function hcountSummary():String
		{
			if (!hcount) return "";
			var l:Array = [];
			for (var k:String in hcount) l.push({ k: k, v: hcount[k] });
			l.sortOn("v", Array.NUMERIC | Array.DESCENDING);
			var t:Array = [], n:Array = [];
			for each (var e:Object in l)
			{
				if (String(e.k).indexOf("t_") == 0) { if (t.length < 8) t.push(String(e.k).substr(2) + " " + e.v); }
				else if (n.length < 10) n.push(e.k + " " + e.v);
			}
			return "ms: " + t.join(", ") + " | calls: " + n.join(", ");
		}
		private var poolCache:Dictionary = new Dictionary(true);

		/** the constant pool written at code[pc] */
		public function poolAt(code:ByteArray, pc:int):Array
		{
			var m:Object = poolCache[code];
			if (!m) poolCache[code] = m = {};
			var p:Array = m[pc];
			if (p) return p;
			code.position = pc + 3;
			var n:int = code.readUnsignedShort();
			p = [];
			for (var i:int = 0; i < n; i++) p.push(readStr(code));
			m[pc] = p;
			return p;
		}

		// ---- for compiled code that keeps its stack in c.stack (the stack is shared with exec)

		public function a_resume(c:Ctx, code:ByteArray, pc:int, end:int):void { exec(code, pc, end, c, pc); }
		public function a_escape(c:Ctx, code:ByteArray, target:int, end:int):void { escape(code, target, end, c); }
		public function a_op(c:Ctx, code:ByteArray, pc:int, end:int):void { if (hcount) hcount["a_op"] = (hcount["a_op"] | 0) + 1; exec(code, pc, end, c); }
		public function a_return(c:Ctx):void { c.ret = c.stack.pop(); c.returned = true; }
		public function a_top(st:Array):* { return st.length ? st[st.length - 1] : undefined; }
		public function a_if(st:Array):Boolean { return toBoolean(st.pop()); }
		public function a_dup(st:Array):void { var a:* = st.length ? st[st.length - 1] : undefined; st.push(a); }
		public function a_swap(st:Array):void { var b:* = st.pop(); var a:* = st.pop(); st.push(b); st.push(a); }
		public function a_getVar(c:Ctx):void { if (hcount) hcount["a_getVar"] = (hcount["a_getVar"] | 0) + 1; var st:Array = c.stack; st.push(getVariable(c, toStr(st.pop()))); }
		public function a_setVar(c:Ctx):void { if (hcount) hcount["a_setVar"] = (hcount["a_setVar"] | 0) + 1; var st:Array = c.stack; var v:* = st.pop(); setVariable(c, toStr(st.pop()), v); }
		public function a_getMember(st:Array):void { if (hcount) hcount["a_getMember"] = (hcount["a_getMember"] | 0) + 1; var n:* = st.pop(); var o:* = st.pop(); st.push(getMember(o, n)); }
		public function a_setMember(st:Array):void { if (hcount) hcount["a_setMember"] = (hcount["a_setMember"] | 0) + 1; var v:* = st.pop(); var n:* = st.pop(); var o:* = st.pop(); setMember(o, n, v); }
		public function a_add2(st:Array):void { var b:* = st.pop(); var a:* = st.pop(); st.push(add2(a, b)); }
		public function a_less2(st:Array):void { var b:* = st.pop(); var a:* = st.pop(); st.push(lessThan(a, b)); }
		public function a_greater(st:Array):void { var b:* = st.pop(); var a:* = st.pop(); st.push(lessThan(b, a)); }
		public function a_eq2(st:Array):void { var b:* = st.pop(); var a:* = st.pop(); st.push(looseEquals(a, b)); }
		public function a_strictEq(st:Array):void { var b:* = st.pop(); var a:* = st.pop(); st.push(strictEquals(a, b)); }
		public function a_not(st:Array):void { st.push(boolResult(!toBoolean(st.pop()))); }
		public function a_add(st:Array):void { var b:* = st.pop(); var a:* = st.pop(); st.push(toNumber(a) + toNumber(b)); }
		public function a_sub(st:Array):void { var b:* = st.pop(); var a:* = st.pop(); st.push(toNumber(a) - toNumber(b)); }
		public function a_mul(st:Array):void { var b:* = st.pop(); var a:* = st.pop(); st.push(toNumber(a) * toNumber(b)); }
		public function a_mod(st:Array):void { var b:* = st.pop(); var a:* = st.pop(); st.push(toNumber(a) % toNumber(b)); }
		public function a_div(st:Array):void { var b:* = st.pop(); var a:* = st.pop(); st.push(h_div(a, b)); }
		public function a_inc(st:Array):void { st.push(toNumber(st.pop()) + 1); }
		public function a_dec(st:Array):void { st.push(toNumber(st.pop()) - 1); }
		public function a_equals(st:Array):void { var b:* = st.pop(); var a:* = st.pop(); st.push(boolResult(toNumber(a) == toNumber(b))); }
		public function a_getProp(c:Ctx):void { var st:Array = c.stack; var n:* = st.pop(); var t:* = st.pop(); st.push(h_getProp(c, t, n)); }
		public function a_setProp(c:Ctx):void { var st:Array = c.stack; var v:* = st.pop(); var n:* = st.pop(); var t:* = st.pop(); h_setProp(c, t, n, v); }
		public function a_callMethod(st:Array):void
		{ if (hcount) hcount["a_callMethod"] = (hcount["a_callMethod"] | 0) + 1;
			var b:* = st.pop(); var a:* = st.pop();
			var args:Array = popArgs(st);
			st.push(callMethod(a, b, args));
		}
		public function a_callFunction(c:Ctx):void
		{ if (hcount) hcount["a_callFunction"] = (hcount["a_callFunction"] | 0) + 1;
			var st:Array = c.stack;
			var name:* = st.pop();
			var args:Array = popArgs(st);
			args.reverse();
			st.push(h_callFunction(c, name, args));
		}

		/** compiled code reached something it doesn't translate: the interpreter goes on from pc */
		public function h_resume(c:Ctx, code:ByteArray, pc:int, end:int, stack:Array):void
		{
			c.stack = stack;
			exec(code, pc, end, c, pc);
		}

		/** compiled code jumped out of its block */
		public function h_escape(c:Ctx, code:ByteArray, target:int, end:int, stack:Array):void
		{
			c.stack = stack;
			escape(code, target, end, c);
		}

		public function h_pool(c:Ctx, code:ByteArray, pc:int):void
		{
			c.pool = poolAt(code, pc);
		}

		public function h_getProp(c:Ctx, t:*, n:*):*
		{ if (hcount) hcount["h_getProp"] = (hcount["h_getProp"] | 0) + 1;
			var a:AClip = targetClip(c, t);
			return a ? display.getIndexed(a, toInt32(n)) : undefined;
		}

		public function h_setProp(c:Ctx, t:*, n:*, v:*):void
		{ if (hcount) hcount["h_setProp"] = (hcount["h_setProp"] | 0) + 1;
			var a:AClip = targetClip(c, t);
			if (a) display.setIndexed(a, toInt32(n), v);
		}

		public function h_getVar(c:Ctx, name:*):*
		{
			if (hcount) { hcount["h_getVar"] = (hcount["h_getVar"] | 0) + 1; var t0:int = getTimer(); var r:* = getVariable(c, toStr(name)); hcount["t_h_getVar"] = (hcount["t_h_getVar"] | 0) + getTimer() - t0; return r; }
			return getVariable(c, toStr(name));
		}

		public function h_setVar(c:Ctx, name:*, v:*):void
		{ if (hcount) hcount["h_setVar"] = (hcount["h_setVar"] | 0) + 1;
			setVariable(c, toStr(name), v);
		}

		public function h_getMember(obj:*, name:*):*
		{
			if (hcount) { var gk:String = obj is AClip ? "getClip" : "getObj"; hcount[gk] = (hcount[gk] | 0) + 1; var t0:int = getTimer(); var r:* = getMember(obj, name); hcount["t_" + gk] = (hcount["t_" + gk] | 0) + getTimer() - t0; return r; }
			return getMember(obj, name);
		}

		public function h_setMember(obj:*, name:*, v:*):void
		{
			if (hcount) { var sk:String = obj is AClip ? "setClip" : "setObj"; hcount[sk] = (hcount[sk] | 0) + 1; var t0:int = getTimer(); setMember(obj, name, v); hcount["t_" + sk] = (hcount["t_" + sk] | 0) + getTimer() - t0; return; }
			setMember(obj, name, v);
		}

		/** args come in reversed (as the stack held them) */
		public function h_callFunction(c:Ctx, name:*, args:Array):*
		{ if (hcount) hcount["h_callFunction"] = (hcount["h_callFunction"] | 0) + 1;
			args.reverse();
			var s:String = toStr(name);
			lastBase = undefined;
			var f:* = getVariable(c, s);
			if (isFunc(f))
			{
				var fbase:* = lastBase;
				if (fbase is AActivation || fbase == global) fbase = undefined;
				if (fbase === undefined && f is ANative) fbase = c.target;
				return call(f, fbase, args);
			}
			return lib.callGlobal(c, s, args);
		}

		public function h_callMethod(obj:*, name:*, args:Array):*
		{
			args.reverse();
			if (hcount) { hcount["h_callMethod"] = (hcount["h_callMethod"] | 0) + 1; var t0:int = getTimer(); var r:* = callMethod(obj, name, args); hcount["t_h_callMethod"] = (hcount["t_h_callMethod"] | 0) + getTimer() - t0; return r; }
			return callMethod(obj, name, args);
		}

		public function h_add2(a:*, b:*):* { if (hcount) hcount["h_add2"] = (hcount["h_add2"] | 0) + 1; return add2(a, b); }
		public function h_less2(a:*, b:*):* { return lessThan(a, b); }
		public function h_greater(a:*, b:*):* { return lessThan(b, a); }
		public function h_eq2(a:*, b:*):Boolean { return looseEquals(a, b); }
		public function h_strictEq(a:*, b:*):Boolean { return strictEquals(a, b); }
		public function h_not(a:*):* { return boolResult(!toBoolean(a)); }
		public function h_bool(a:*):Boolean { return toBoolean(a); }
		public function h_num(a:*):Number { return toNumber(a); }
		public function h_div(a:*, b:*):* { var d:Number = toNumber(b); return d == 0 && version < 5 ? "#ERROR#" : toNumber(a) / d; }

		public function h_return(c:Ctx, v:*):void
		{
			c.ret = v;
			c.returned = true;
		}

		/** a loop went round: the same endless-loop guard as the interpreter */
		public function h_loop():void
		{ if (hcount) hcount["h_loop"] = (hcount["h_loop"] | 0) + 1;
			budget += 20;
			instrCount += 20;
			if (budget > maxSteps) throw new Error("script runs too long (endless loop?)");
		}

		/** any other action: run it with the interpreter on a stack of its inputs; returns its outputs */
		public function h_op(c:Ctx, code:ByteArray, pc:int, end:int, ins:Array):Array
		{
			if (hcount) { hcount["h_op"] = (hcount["h_op"] | 0) + 1; hcount["op" + code[pc].toString(16)] = (hcount["op" + code[pc].toString(16)] | 0) + 1; }
			var saved:Array = c.stack;
			c.stack = ins;
			var out:Array;
			try { exec(code, pc, end, c); }
			finally { out = c.stack; c.stack = saved; }
			return out;
		}

		private function popArgs(st:Array):Array
		{
			var n:int = toInt32(st.pop());
			var args:Array = [];
			for (var i:int = 0; i < n; i++) args.push(st.pop());
			return args;
		}

		private function gotoFrame2(c:Ctx, frame:*, play:Boolean, bias:int):void
		{
			var target:AClip = c.target;
			if (frame is String)
			{
				var fs:String = frame;
				var colon:int = fs.lastIndexOf(":");
				if (colon >= 0)
				{
					target = targetClip(c, fs.substr(0, colon));
					fs = fs.substr(colon + 1);
				}
				var num:Number = Number(fs);
				if (fs != "" && !isNaN(num)) frame = int(num) + bias;
				else frame = fs;
			}
			else
			{
				frame = toInt32(frame) + bias;
			}
			if (target) display.gotoFrame(target, frame, play);
		}

		private function callFrame(c:Ctx, frame:*):void
		{
			var target:AClip = c.target;
			var fs:String = toStr(frame);
			var colon:int = fs.lastIndexOf(":");
			if (colon >= 0)
			{
				target = targetClip(c, fs.substr(0, colon));
				fs = fs.substr(colon + 1);
			}
			if (target) display.callFrame(target, fs);
		}

		private function doTry(code:ByteArray, body:int, len:int, c:Ctx):int
		{
			code.position = body;
			var flags:int = code.readUnsignedByte();
			var trySize:int = code.readUnsignedShort();
			var catchSize:int = code.readUnsignedShort();
			var finallySize:int = code.readUnsignedShort();
			var catchName:String = null;
			var catchReg:int = -1;
			if (flags & 4) catchReg = code.readUnsignedByte();
			else catchName = readStr(code);
			var tStart:int = body + len;
			var cStart:int = tStart + trySize;
			var fStart:int = cStart + catchSize;
			var fEnd:int = fStart + finallySize;
			var stop:int = cStart;
			var pending:AThrow = null;
			try
			{
				stop = exec(code, tStart, cStart, c);
			}
			catch (t:AThrow)
			{
				if (flags & 1)
				{
					if (catchReg >= 0) c.regs[catchReg] = t.value;
					else defineLocal(c, catchName, t.value);
					try { stop = exec(code, cStart, fStart, c); }
					catch (t2:AThrow) { pending = t2; }
				}
				else
				{
					pending = t;
				}
			}
			if (flags & 2)
			{
				var wasReturned:Boolean = c.returned;
				c.returned = false;
				exec(code, fStart, fEnd, c);
				if (wasReturned) c.returned = true;
			}
			if (pending) throw pending;
			if (stop >= tStart && stop < fEnd) return fEnd;
			if (stop == cStart || stop == fStart) return fEnd;
			return stop;
		}

		/** SWF version of the movie: strings before SWF 6 aren't UTF-8 */
		public static var stringVersion:int = 6;

		/** decoded strings: code block -> { position -> [string, next position] } */
		private static var strCache:Dictionary = new Dictionary(true);

		/** code -> { pc -> PushOp }: Push actions decoded once */
		private var pushCache:Dictionary = new Dictionary(true);

		private function pushOf(code:ByteArray, body:int, next:int):PushOp
		{
			var pu:PushOp = new PushOp();
			var keep:uint = code.position;
			code.position = body;
			while (code.position < next)
			{
				var t:int = code.readUnsignedByte();
				switch (t)
				{
					case 0: pu.add(0, readStr(code)); break;
					case 1: pu.add(0, code.readFloat()); break;
					case 2: pu.add(0, null); break;
					case 3: pu.add(0, undefined); break;
					case 4: pu.add(1, code.readUnsignedByte()); break;
					case 5: pu.add(0, code.readUnsignedByte() != 0); break;
					case 6: pu.add(0, readDouble(code)); break;
					case 7: pu.add(0, Number(code.readInt())); break;
					case 8: pu.add(2, code.readUnsignedByte()); break;
					case 9: pu.add(2, code.readUnsignedShort()); break;
					default: code.position = next;
				}
			}
			code.position = keep;
			return pu;
		}

		public static function readStr(b:ByteArray):String
		{
			var start:uint = b.position;
			var cache:Object = strCache[b];
			if (cache)
			{
				var hit:Array = cache[start];
				if (hit) { b.position = hit[1]; return hit[0]; }
			}
			else
			{
				strCache[b] = cache = {};
			}
			var len:uint = b.length;
			var p:uint = start;
			var ascii:Boolean = true;
			while (p < len && b[p] != 0) { if (b[p] >= 0x80) ascii = false; p++; }
			var n:uint = p - start;
			var s:String;
			if (n == 0) s = "";
			else if (ascii) { b.position = start; s = b.readUTFBytes(n); }
			else s = decodeStr(b, start, n);
			b.position = start + n + 1;
			cache[start] = [s, b.position];
			return s;
		}

		/**
		 * UTF-8 (SWF 6+) where it is valid. Bytes that aren't valid UTF-8 (obfuscated names, or
		 * the Windows code page of SWF 5 and older) each map to their own character, so two
		 * different names never come out as the same string.
		 */
		private static function decodeStr(b:ByteArray, start:uint, n:uint):String
		{
			var out:Array = [];
			var end:uint = start + n;
			var p:uint = start;
			var oldSwf:Boolean = stringVersion < 6;
			while (p < end)
			{
				var c:int = b[p];
				var cp:int = -1;
				var need:int = 0;
				if (c < 0x80) { cp = c; need = 0; }
				else if (c >= 0xC2 && c <= 0xDF) { cp = c & 0x1F; need = 1; }
				else if (c >= 0xE0 && c <= 0xEF) { cp = c & 0x0F; need = 2; }
				else if (c >= 0xF0 && c <= 0xF4) { cp = c & 0x07; need = 3; }
				if (need > 0)
				{
					if (p + need >= end) cp = -1;
					else
					{
						for (var k:int = 1; k <= need; k++)
						{
							var cc:int = p + k < end ? b[p + k] : 0;
							if ((cc & 0xC0) != 0x80) { cp = -1; break; }
							cp = (cp << 6) | (cc & 0x3F);
						}
						// overlong / surrogate / out of range: not valid
						if (cp >= 0 && ((need == 2 && (cp < 0x800 || (cp >= 0xD800 && cp <= 0xDFFF))) ||
							(need == 3 && (cp < 0x10000 || cp > 0x10FFFF)))) cp = -1;
					}
				}
				if (cp < 0)
				{
					// one byte on its own
					out.push(oldSwf ? cp1251(c) : 0xF700 + c); // private use area: valid, and AIR keeps it
					p++;
					continue;
				}
				if (cp >= 0x10000)
				{
					cp -= 0x10000;
					out.push(0xD800 + (cp >> 10), 0xDC00 + (cp & 0x3FF));
				}
				else out.push(cp);
				p += need + 1;
			}
			var s:String = "";
			for (var i:int = 0; i < out.length; i += 4096)
				s += String.fromCharCode.apply(null, out.slice(i, i + 4096));
			return s;
		}

		/** the string as UTF-8 bytes (what AIR reads back as the same string) */
		public static function strBytes(s:String):ByteArray
		{
			var b:ByteArray = new ByteArray();
			b.writeUTFBytes(s);
			return b;
		}

		private static const CP1251_80:Array = [0x0402, 0x0403, 0x201A, 0x0453, 0x201E, 0x2026, 0x2020, 0x2021,
			0x20AC, 0x2030, 0x0409, 0x2039, 0x040A, 0x040C, 0x040B, 0x040F, 0x0452, 0x2018, 0x2019, 0x201C,
			0x201D, 0x2022, 0x2013, 0x2014, 0x0098, 0x2122, 0x0459, 0x203A, 0x045A, 0x045C, 0x045B, 0x045F,
			0x00A0, 0x040E, 0x045E, 0x0408, 0x00A4, 0x0490, 0x00A6, 0x00A7, 0x0401, 0x00A9, 0x0404, 0x00AB,
			0x00AC, 0x00AD, 0x00AE, 0x0407, 0x00B0, 0x00B1, 0x0406, 0x0456, 0x0491, 0x00B5, 0x00B6, 0x00B7,
			0x0451, 0x2116, 0x0454, 0x00BB, 0x0458, 0x0405, 0x0455, 0x0457];

		/** Windows-1251 (what Flash 5 showed on Russian systems) */
		private static function cp1251(c:int):int
		{
			if (c < 0x80) return c;
			if (c >= 0xC0) return 0x0410 + (c - 0xC0);
			return CP1251_80[c - 0x80];
		}

		private static var dbl:ByteArray;

		private static function readDouble(b:ByteArray):Number
		{
			if (!dbl) { dbl = new ByteArray(); dbl.endian = Endian.LITTLE_ENDIAN; }
			var hi:uint = b.readUnsignedInt();
			var lo:uint = b.readUnsignedInt();
			dbl.position = 0;
			dbl.writeUnsignedInt(lo);
			dbl.writeUnsignedInt(hi);
			dbl.position = 0;
			return dbl.readDouble();
		}
	}
}
