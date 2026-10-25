package fp.avm1
{
	import flash.display.Graphics;
	import flash.display.MovieClip;
	import flash.events.Event;
	import flash.events.TimerEvent;
	import flash.media.Sound;
	import flash.media.SoundChannel;
	import flash.media.SoundMixer;
	import flash.media.SoundTransform;
	import flash.text.TextField;
	import flash.text.TextFormat;
	import flash.utils.Dictionary;
	import flash.utils.Timer;
	import flash.utils.getTimer;

	/** Built-in objects and functions of ActionScript 1/2 for the AVM1 engine. */
	public class VmLib
	{
		private var vm:Vm;

		private var keys:Object = {};
		private var lastKey:int = 0;
		private var lastAscii:int = 0;
		private var keyListeners:Array = [];
		private var mouseListeners:Array = [];
		private var intervals:Object = {};
		private var nextInterval:int = 1;
		private var sounds:Dictionary = new Dictionary(true);
		/** every channel ever started (strong refs, so they can all be stopped on close) */
		private var channels:Array = [];
		private var soundLogs:int = 0;
		private var colors:Dictionary = new Dictionary(true);

		/** save games: storage.load(name):String / storage.save(name, json) — set by the player */
		public var storage:Object;

		public function VmLib(vm:Vm)
		{
			this.vm = vm;
		}

		// ================================================================= helpers

		private function fn(o:AObject, name:String, f:Function):ANative
		{
			return vm.defFn(o, name, f);
		}

		private function num(v:*):Number { return vm.toNumber(v); }
		private function str(v:*):String { return vm.toStr(v); }

		private function ctor(name:String, proto:AObject, call:Function, construct:Function = null):ANative
		{
			var n:ANative = vm.nat(name, call, construct);
			vm.def(n, "prototype", proto);
			if (proto) proto.setOwn(vm.key("constructor"), n);
			vm.def(vm.global, name, n);
			return n;
		}

		private function clip(t:*):AClip
		{
			return t as AClip;
		}

		// ================================================================= setup

		public function setup():void
		{
			var g:AObject = vm.global;
			var op:AObject = vm.objectProto;

			// ----------------------------------------------------------- Object / Function
			fn(op, "toString", function(t:*, a:Array):* { return t is AClip ? vm.toStr(t) : "[object Object]"; });
			fn(op, "valueOf", function(t:*, a:Array):* { return t; });
			fn(op, "hasOwnProperty", function(t:*, a:Array):* {
				return t is AObject ? (t as AObject).hasOwn(vm.key(str(a[0]))) : false;
			});
			fn(op, "isPropertyEnumerable", function(t:*, a:Array):* {
				return t is AObject ? (t as AObject).hasOwn(vm.key(str(a[0]))) : false;
			});
			fn(op, "isPrototypeOf", function(t:*, a:Array):* {
				var o:AObject = a[0] is AObject ? (a[0] as AObject).proto : null;
				while (o) { if (o == t) return true; o = o.proto; }
				return false;
			});
			fn(op, "addProperty", function(t:*, a:Array):* {
				if (!(t is AObject) || !vm.isFunc(a[1])) return false;
				(t as AObject).setAccessor(vm.key(str(a[0])), a[1], vm.isFunc(a[2]) ? a[2] : null);
				return true;
			});
			fn(op, "watch", function(t:*, a:Array):* { return false; });
			fn(op, "unwatch", function(t:*, a:Array):* { return false; });
			var objectCtor:ANative = ctor("Object", op, function(t:*, a:Array):* {
				return a.length && a[0] !== undefined && a[0] !== null ? a[0] : vm.newObject();
			}, function(a:Array):* {
				return a.length && (a[0] is AObject) ? a[0] : vm.newObject();
			});
			fn(objectCtor, "registerClass", function(t:*, a:Array):* {
				vm.registered[str(a[0]).toLowerCase()] = a[1];
				if (vm.debug) vm.log("avm1: registerClass " + str(a[0]) + " " + (a[1] is AObject));
				return true;
			});

			var fp:AObject = vm.functionProto;
			fn(fp, "call", function(t:*, a:Array):* { return vm.call(t, a[0], a.slice(1)); });
			fn(fp, "apply", function(t:*, a:Array):* {
				var args:Array = a[1] is Array ? (a[1] as Array).concat() : [];
				return vm.call(t, a[0], args);
			});
			ctor("Function", fp, function(t:*, a:Array):* { return undefined; });

			// ----------------------------------------------------------- primitives
			vm.stringProto = new AObject(op);
			var sp:AObject = vm.stringProto;
			fn(sp, "toString", function(t:*, a:Array):* { return str(t); });
			fn(sp, "valueOf", function(t:*, a:Array):* { return str(t); });
			fn(sp, "charAt", function(t:*, a:Array):* { return str(t).charAt(int(num(a[0]))); });
			fn(sp, "charCodeAt", function(t:*, a:Array):* { var s:String = str(t); var i:int = int(num(a[0])); return i >= 0 && i < s.length ? s.charCodeAt(i) : NaN; });
			fn(sp, "indexOf", function(t:*, a:Array):* { return str(t).indexOf(str(a[0]), a.length > 1 ? int(num(a[1])) : 0); });
			fn(sp, "lastIndexOf", function(t:*, a:Array):* { return a.length > 1 ? str(t).lastIndexOf(str(a[0]), int(num(a[1]))) : str(t).lastIndexOf(str(a[0])); });
			fn(sp, "substr", function(t:*, a:Array):* {
				var s:String = str(t);
				var st:int = int(num(a[0]));
				if (st < 0) st = Math.max(0, s.length + st);
				return a.length > 1 && a[1] !== undefined ? s.substr(st, int(num(a[1]))) : s.substr(st);
			});
			fn(sp, "substring", function(t:*, a:Array):* {
				var s:String = str(t);
				var x:int = int(num(a[0])); if (isNaN(num(a[0])) || x < 0) x = 0;
				var y:int = a.length > 1 && a[1] !== undefined ? int(num(a[1])) : s.length;
				return s.substring(x, y);
			});
			fn(sp, "slice", function(t:*, a:Array):* {
				var s:String = str(t);
				return a.length > 1 && a[1] !== undefined ? s.slice(int(num(a[0])), int(num(a[1]))) : s.slice(int(num(a[0])));
			});
			fn(sp, "split", function(t:*, a:Array):* {
				var s:String = str(t);
				if (a[0] === undefined) return [s];
				var parts:Array = s.split(str(a[0]));
				if (a.length > 1 && a[1] !== undefined) parts = parts.slice(0, int(num(a[1])));
				return parts;
			});
			fn(sp, "toUpperCase", function(t:*, a:Array):* { return str(t).toUpperCase(); });
			fn(sp, "toLowerCase", function(t:*, a:Array):* { return str(t).toLowerCase(); });
			fn(sp, "concat", function(t:*, a:Array):* { var s:String = str(t); for each (var x:* in a) s += str(x); return s; });
			var stringCtor:ANative = ctor("String", sp, function(t:*, a:Array):* { return a.length ? str(a[0]) : ""; },
				function(a:Array):* { return a.length ? str(a[0]) : ""; });
			fn(stringCtor, "fromCharCode", function(t:*, a:Array):* {
				var s:String = "";
				for each (var x:* in a) s += String.fromCharCode(int(num(x)));
				return s;
			});

			vm.numberProto = new AObject(op);
			fn(vm.numberProto, "toString", function(t:*, a:Array):* {
				var n:Number = num(t);
				var radix:int = a.length && a[0] !== undefined ? int(num(a[0])) : 10;
				return radix == 10 ? vm.numToStr(n) : int(n).toString(radix);
			});
			fn(vm.numberProto, "valueOf", function(t:*, a:Array):* { return num(t); });
			var numberCtor:ANative = ctor("Number", vm.numberProto, function(t:*, a:Array):* { return a.length ? num(a[0]) : 0; },
				function(a:Array):* { return a.length ? num(a[0]) : 0; });
			vm.def(numberCtor, "MAX_VALUE", Number.MAX_VALUE);
			vm.def(numberCtor, "MIN_VALUE", Number.MIN_VALUE);
			vm.def(numberCtor, "NaN", NaN);
			vm.def(numberCtor, "POSITIVE_INFINITY", Infinity);
			vm.def(numberCtor, "NEGATIVE_INFINITY", -Infinity);

			vm.booleanProto = new AObject(op);
			fn(vm.booleanProto, "toString", function(t:*, a:Array):* { return vm.toBoolean(t) ? "true" : "false"; });
			fn(vm.booleanProto, "valueOf", function(t:*, a:Array):* { return vm.toBoolean(t); });
			ctor("Boolean", vm.booleanProto, function(t:*, a:Array):* { return vm.toBoolean(a[0]); },
				function(a:Array):* { return vm.toBoolean(a[0]); });

			// ----------------------------------------------------------- Array
			vm.arrayProto = new AObject(op);
			var ap:AObject = vm.arrayProto;
			fn(ap, "push", function(t:*, a:Array):* { var r:Array = t as Array; if (!r) return undefined; for each (var x:* in a) r.push(x); return r.length; });
			fn(ap, "pop", function(t:*, a:Array):* { return t is Array ? (t as Array).pop() : undefined; });
			fn(ap, "shift", function(t:*, a:Array):* { return t is Array ? (t as Array).shift() : undefined; });
			fn(ap, "unshift", function(t:*, a:Array):* { var r:Array = t as Array; if (!r) return undefined; for (var i:int = a.length - 1; i >= 0; i--) r.unshift(a[i]); return r.length; });
			fn(ap, "splice", function(t:*, a:Array):* {
				var r:Array = t as Array; if (!r) return undefined;
				var st:int = int(num(a[0])); if (st < 0) st = Math.max(0, r.length + st);
				var cnt:int = a.length > 1 ? int(num(a[1])) : r.length - st;
				var args:Array = [st, cnt].concat(a.slice(2));
				return r.splice.apply(r, args);
			});
			fn(ap, "slice", function(t:*, a:Array):* {
				var r:Array = t as Array; if (!r) return undefined;
				return a.length > 1 && a[1] !== undefined ? r.slice(int(num(a[0])), int(num(a[1]))) : r.slice(a.length ? int(num(a[0])) : 0);
			});
			fn(ap, "join", function(t:*, a:Array):* {
				var r:Array = t as Array; if (!r) return "";
				var sep:String = a.length && a[0] !== undefined ? str(a[0]) : ",";
				var parts:Array = [];
				for each (var x:* in r) parts.push(x === undefined || x === null ? "" : str(x));
				return parts.join(sep);
			});
			fn(ap, "toString", function(t:*, a:Array):* { return str(t); });
			fn(ap, "reverse", function(t:*, a:Array):* { return t is Array ? (t as Array).reverse() : t; });
			fn(ap, "concat", function(t:*, a:Array):* {
				var r:Array = t is Array ? (t as Array).concat() : [];
				for each (var x:* in a) { if (x is Array) r = r.concat(x); else r.push(x); }
				return r;
			});
			fn(ap, "sort", function(t:*, a:Array):* {
				var r:Array = t as Array; if (!r) return t;
				var cmp:* = vm.isFunc(a[0]) ? a[0] : null;
				var opts:int = vm.isFunc(a[0]) ? int(num(a[1])) : int(num(a[0]));
				if (cmp) r.sort(function(x:*, y:*):Number { return num(vm.call(cmp, undefined, [x, y])); });
				else if (opts & 16) r.sort(function(x:*, y:*):Number { return (opts & 2) ? num(y) - num(x) : num(x) - num(y); });
				else r.sort(function(x:*, y:*):Number {
					var sx:String = str(x), sy:String = str(y);
					if (opts & 1) { sx = sx.toLowerCase(); sy = sy.toLowerCase(); }
					var c:Number = sx < sy ? -1 : sx > sy ? 1 : 0;
					return (opts & 2) ? -c : c;
				});
				return r;
			});
			fn(ap, "sortOn", function(t:*, a:Array):* {
				var r:Array = t as Array; if (!r) return t;
				var field:String = str(a[0]);
				var opts:int = int(num(a[1]));
				r.sort(function(x:*, y:*):Number {
					var vx:* = vm.getMember(x, field), vy:* = vm.getMember(y, field);
					var c:Number;
					if (opts & 16) c = num(vx) - num(vy);
					else
					{
						var sx:String = str(vx), sy:String = str(vy);
						if (opts & 1) { sx = sx.toLowerCase(); sy = sy.toLowerCase(); }
						c = sx < sy ? -1 : sx > sy ? 1 : 0;
					}
					return (opts & 2) ? -c : c;
				});
				return r;
			});
			var arrayCtor:ANative = ctor("Array", ap, function(t:*, a:Array):* { return makeArray(a); }, makeArray);
			vm.def(arrayCtor, "CASEINSENSITIVE", 1);
			vm.def(arrayCtor, "DESCENDING", 2);
			vm.def(arrayCtor, "UNIQUESORT", 4);
			vm.def(arrayCtor, "RETURNINDEXEDARRAY", 8);
			vm.def(arrayCtor, "NUMERIC", 16);

			// ----------------------------------------------------------- Date
			vm.dateProto = new AObject(op);
			for each (var dm:String in ["getTime", "getFullYear", "getMonth", "getDate", "getDay", "getHours", "getMinutes",
				"getSeconds", "getMilliseconds", "getUTCFullYear", "getUTCMonth", "getUTCDate", "getUTCDay", "getUTCHours",
				"getUTCMinutes", "getUTCSeconds", "getUTCMilliseconds", "getTimezoneOffset", "setTime", "setFullYear",
				"setMonth", "setDate", "setHours", "setMinutes", "setSeconds", "setMilliseconds", "toString", "valueOf"])
			{
				fn(vm.dateProto, dm, dateMethod(dm));
			}
			fn(vm.dateProto, "getYear", function(t:*, a:Array):* { return t is Date ? (t as Date).fullYear - 1900 : NaN; });
			var dateCtor:ANative = ctor("Date", vm.dateProto, function(t:*, a:Array):* { return new Date().toString(); }, makeDate);
			fn(dateCtor, "UTC", function(t:*, a:Array):* {
				var n:Array = [];
				for each (var x:* in a) n.push(num(x));
				return Date.UTC.apply(null, n);
			});

			// ----------------------------------------------------------- Math
			var math:AObject = vm.newObject();
			vm.def(g, "Math", math);
			for each (var mf:String in ["abs", "acos", "asin", "atan", "atan2", "ceil", "cos", "exp", "floor", "log",
				"max", "min", "pow", "round", "sin", "sqrt", "tan"])
			{
				fn(math, mf, mathFn(mf));
			}
			fn(math, "random", function(t:*, a:Array):* { return Math.random(); });
			vm.def(math, "E", Math.E);
			vm.def(math, "LN10", Math.LN10);
			vm.def(math, "LN2", Math.LN2);
			vm.def(math, "LOG10E", Math.LOG10E);
			vm.def(math, "LOG2E", Math.LOG2E);
			vm.def(math, "PI", Math.PI);
			vm.def(math, "SQRT1_2", Math.SQRT1_2);
			vm.def(math, "SQRT2", Math.SQRT2);

			// ----------------------------------------------------------- globals
			vm.def(g, "NaN", NaN);
			vm.def(g, "Infinity", Infinity);
			fn(g, "trace", function(t:*, a:Array):* { vm.log("trace: " + str(a[0])); return undefined; });
			fn(g, "parseInt", function(t:*, a:Array):* {
				var s:String = str(a[0]).replace(/^\s+/, "");
				var radix:int = a.length > 1 && a[1] !== undefined ? int(num(a[1])) : 0;
				return radix ? parseInt(s, radix) : parseInt(s);
			});
			fn(g, "parseFloat", function(t:*, a:Array):* { return parseFloat(str(a[0])); });
			fn(g, "isNaN", function(t:*, a:Array):* { return isNaN(num(a[0])); });
			fn(g, "isFinite", function(t:*, a:Array):* { return isFinite(num(a[0])); });
			fn(g, "escape", function(t:*, a:Array):* { return escape(str(a[0])); });
			fn(g, "unescape", function(t:*, a:Array):* { return unescape(str(a[0])); });
			fn(g, "getTimer", function(t:*, a:Array):* { return getTimer() - vm.display.startTime; });
			fn(g, "getVersion", function(t:*, a:Array):* { return "WIN 10,0,0,0"; });
			fn(g, "updateAfterEvent", function(t:*, a:Array):* { return undefined; });
			fn(g, "ASSetPropFlags", function(t:*, a:Array):* { return undefined; });
			fn(g, "fscommand", function(t:*, a:Array):* { getURL(null, "FSCommand:" + str(a[0]), str(a[1])); return undefined; });
			fn(g, "setInterval", function(t:*, a:Array):* { return addInterval(a, true); });
			fn(g, "setTimeout", function(t:*, a:Array):* { return addInterval(a, false); });
			fn(g, "clearInterval", function(t:*, a:Array):* { clearTimer(int(num(a[0]))); return undefined; });
			fn(g, "clearTimeout", function(t:*, a:Array):* { clearTimer(int(num(a[0]))); return undefined; });

			// ----------------------------------------------------------- display classes
			setupClip(op);

			// ----------------------------------------------------------- Key / Mouse / Stage / System
			var key:AObject = vm.newObject();
			vm.def(g, "Key", key);
			fn(key, "isDown", function(t:*, a:Array):* { return isDown(int(num(a[0]))); });
			fn(key, "isToggled", function(t:*, a:Array):* { return false; });
			fn(key, "getCode", function(t:*, a:Array):* { return lastKey; });
			fn(key, "getAscii", function(t:*, a:Array):* { return lastAscii; });
			fn(key, "addListener", function(t:*, a:Array):* { if (keyListeners.indexOf(a[0]) < 0) keyListeners.push(a[0]); return true; });
			fn(key, "removeListener", function(t:*, a:Array):* { var i:int = keyListeners.indexOf(a[0]); if (i >= 0) keyListeners.splice(i, 1); return i >= 0; });
			var kc:Object = { BACKSPACE: 8, CAPSLOCK: 20, CONTROL: 17, DELETEKEY: 46, DOWN: 40, END: 35, ENTER: 13,
				ESCAPE: 27, HOME: 36, INSERT: 45, LEFT: 37, PGDN: 34, PGUP: 33, RIGHT: 39, SHIFT: 16, SPACE: 32, TAB: 9, UP: 38 };
			for (var kn:String in kc) vm.def(key, kn, kc[kn]);

			var mouse:AObject = vm.newObject();
			vm.def(g, "Mouse", mouse);
			fn(mouse, "show", function(t:*, a:Array):* { return 0; });
			fn(mouse, "hide", function(t:*, a:Array):* { return 0; });
			fn(mouse, "addListener", function(t:*, a:Array):* { if (mouseListeners.indexOf(a[0]) < 0) mouseListeners.push(a[0]); return true; });
			fn(mouse, "removeListener", function(t:*, a:Array):* { var i:int = mouseListeners.indexOf(a[0]); if (i >= 0) mouseListeners.splice(i, 1); return i >= 0; });

			var stage:AObject = vm.newObject();
			vm.def(g, "Stage", stage);
			stage.setAccessor(vm.key("width"), vm.nat("width", function(t:*, a:Array):* { return vm.display.root ? vm.display.root.loaderInfo.width : 550; }), null);
			stage.setAccessor(vm.key("height"), vm.nat("height", function(t:*, a:Array):* { return vm.display.root ? vm.display.root.loaderInfo.height : 400; }), null);
			vm.def(stage, "scaleMode", "showAll");
			vm.def(stage, "align", "");
			vm.def(stage, "showMenu", false);
			fn(stage, "addListener", function(t:*, a:Array):* { return true; });
			fn(stage, "removeListener", function(t:*, a:Array):* { return true; });

			var system:AObject = vm.newObject();
			vm.def(g, "System", system);
			var caps:AObject = vm.newObject();
			vm.def(system, "capabilities", caps);
			vm.def(caps, "os", "Android");
			vm.def(caps, "version", "WIN 10,0,0,0");
			vm.def(caps, "playerType", "StandAlone");
			vm.def(caps, "hasAudio", true);
			vm.def(caps, "language", "en");
			var security:AObject = vm.newObject();
			vm.def(system, "security", security);
			fn(security, "allowDomain", function(t:*, a:Array):* { return true; });
			fn(security, "allowInsecureDomain", function(t:*, a:Array):* { return true; });
			fn(security, "loadPolicyFile", function(t:*, a:Array):* { return true; });
			vm.def(system, "useCodepage", false);

			var selection:AObject = vm.newObject();
			vm.def(g, "Selection", selection);
			fn(selection, "setFocus", function(t:*, a:Array):* { return false; });
			fn(selection, "getFocus", function(t:*, a:Array):* { return null; });
			fn(selection, "addListener", function(t:*, a:Array):* { return true; });

			// ----------------------------------------------------------- Sound / Color / TextFormat
			setupSound(op);
			setupColor(op);
			vm.def(g, "TextFormat", vm.nat("TextFormat", function(t:*, a:Array):* { return undefined; }, makeTextFormat));

			// ----------------------------------------------------------- stubs
			var so:AObject = vm.newObject();
			vm.def(g, "SharedObject", so);
			fn(so, "getLocal", function(t:*, a:Array):* { return sharedObject(str(a[0])); });
			// no network: loads fail the way they do offline (onLoad(false) a moment later)
			for each (var netClass:String in ["LoadVars", "XML"])
			{
				var np:AObject = new AObject(op);
				fn(np, "load", failLoad);
				fn(np, "sendAndLoad", function(t2:*, a2:Array):* { if (a2[1] is AObject) failLoad(a2[1], []); return true; });
				fn(np, "send", function(t2:*, a2:Array):* { return false; });
				fn(np, "parseXML", function(t2:*, a2:Array):* { return undefined; });
				fn(np, "toString", function(t2:*, a2:Array):* { return ""; });
				fn(np, "getBytesLoaded", function(t2:*, a2:Array):* { return 0; });
				fn(np, "getBytesTotal", function(t2:*, a2:Array):* { return 0; });
				fn(np, "addRequestHeader", function(t2:*, a2:Array):* { return undefined; });
				ctor(netClass, np, function(t:*, a:Array):* { return undefined; }, netCtor(np));
			}
			var cm:ANative = ctor("ContextMenu", new AObject(op), function(t:*, a:Array):* { return undefined; }, function(a:Array):* {
				var o:AObject = vm.newObject();
				fn(o, "hideBuiltInItems", function(t2:*, a2:Array):* { return undefined; });
				vm.def(o, "customItems", []);
				return o;
			});
			ctor("ContextMenuItem", new AObject(op), function(t:*, a:Array):* { return undefined; }, function(a:Array):* { return vm.newObject(); });
		}

		private function netCtor(p:AObject):Function
		{
			return function(a:Array):* {
				var o:AObject = new AObject(p);
				vm.objSet(o, "loaded", false);
				vm.objSet(o, "firstChild", null);
				vm.objSet(o, "childNodes", []);
				return o;
			};
		}

		private function failLoad(t:*, a:Array):*
		{
			var target:* = t;
			var timer:Timer = new Timer(50, 1);
			timer.addEventListener(TimerEvent.TIMER, function(e:TimerEvent):void {
				var f:* = vm.getMember(target, "onLoad");
				if (vm.isFunc(f)) vm.callHandler(f, target, [false]);
			});
			timer.start();
			return true;
		}

		// ================================================================= MovieClip & co.

		private function setupClip(op:AObject):void
		{
			vm.clipProto = new AObject(op);
			var cp:AObject = vm.clipProto;
			var d:VmDisplay = vm.display;
			fn(cp, "play", function(t:*, a:Array):* { d.play(clip(t)); return undefined; });
			fn(cp, "stop", function(t:*, a:Array):* { d.stop(clip(t)); return undefined; });
			fn(cp, "nextFrame", function(t:*, a:Array):* { d.nextFrame(clip(t)); return undefined; });
			fn(cp, "prevFrame", function(t:*, a:Array):* { d.prevFrame(clip(t)); return undefined; });
			fn(cp, "gotoAndPlay", function(t:*, a:Array):* { d.gotoFrame(clip(t), frameArg(a), true); return undefined; });
			fn(cp, "gotoAndStop", function(t:*, a:Array):* { d.gotoFrame(clip(t), frameArg(a), false); return undefined; });
			fn(cp, "nextScene", function(t:*, a:Array):* { return undefined; });
			fn(cp, "prevScene", function(t:*, a:Array):* { return undefined; });
			fn(cp, "getBytesLoaded", function(t:*, a:Array):* { return 100; });
			fn(cp, "getBytesTotal", function(t:*, a:Array):* { return 100; });
			fn(cp, "hitTest", function(t:*, a:Array):* { return t is AClip ? d.hitTest(t, a) : false; });
			fn(cp, "getBounds", function(t:*, a:Array):* { return t is AClip ? d.getBounds(t, a[0]) : undefined; });
			fn(cp, "getRect", function(t:*, a:Array):* { return t is AClip ? d.getBounds(t, a[0]) : undefined; });
			fn(cp, "localToGlobal", function(t:*, a:Array):* { if (t is AClip) d.localToGlobal(t, a[0], true); return undefined; });
			fn(cp, "globalToLocal", function(t:*, a:Array):* { if (t is AClip) d.localToGlobal(t, a[0], false); return undefined; });
			fn(cp, "attachMovie", function(t:*, a:Array):* {
				return t is AClip ? d.attach(t, str(a[0]), str(a[1]), num(a[2]), a[3]) : undefined;
			});
			fn(cp, "duplicateMovieClip", function(t:*, a:Array):* {
				return t is AClip ? d.duplicate(t, str(a[0]), num(a[1]), a[2]) : undefined;
			});
			fn(cp, "removeMovieClip", function(t:*, a:Array):* { if (t is AClip) d.remove(t); return undefined; });
			fn(cp, "createEmptyMovieClip", function(t:*, a:Array):* {
				return t is AClip ? d.createEmpty(t, str(a[0]), num(a[1])) : undefined;
			});
			fn(cp, "createTextField", function(t:*, a:Array):* {
				return t is AClip ? d.createText(t, str(a[0]), num(a[1]), num(a[2]), num(a[3]), num(a[4]), num(a[5])) : undefined;
			});
			fn(cp, "swapDepths", function(t:*, a:Array):* { if (t is AClip) d.swapDepths(t, a[0]); return undefined; });
			fn(cp, "getDepth", function(t:*, a:Array):* { return t is AClip ? d.getDepth(t) : undefined; });
			fn(cp, "getNextHighestDepth", function(t:*, a:Array):* { return t is AClip ? d.nextDepth(t) : 0; });
			fn(cp, "getInstanceAtDepth", function(t:*, a:Array):* { return t is AClip ? d.instanceAt(t, num(a[0])) : undefined; });
			fn(cp, "startDrag", function(t:*, a:Array):* {
				if (!(t is AClip)) return undefined;
				var rect:Array = a.length >= 5 ? [num(a[1]), num(a[2]), num(a[3]), num(a[4])] : null;
				d.startDrag(t, vm.toBoolean(a[0]), rect);
				return undefined;
			});
			fn(cp, "stopDrag", function(t:*, a:Array):* { d.stopDrag(); return undefined; });
			fn(cp, "setMask", function(t:*, a:Array):* {
				if (t is AClip) try { (t as AClip).d.mask = a[0] is AClip ? (a[0] as AClip).d : null; } catch (e:Error) {}
				return undefined;
			});
			fn(cp, "getURL", function(t:*, a:Array):* { return undefined; });
			fn(cp, "loadMovie", function(t:*, a:Array):* { vm.warnOnce("loadMovie isn't supported"); return undefined; });
			fn(cp, "unloadMovie", function(t:*, a:Array):* { if (t is AClip) d.unload(t); return undefined; });
			fn(cp, "loadVariables", function(t:*, a:Array):* { return undefined; });
			fn(cp, "getSWFVersion", function(t:*, a:Array):* { return vm.version; });
			fn(cp, "toString", function(t:*, a:Array):* { return str(t); });
			// drawing API
			fn(cp, "clear", function(t:*, a:Array):* { var gr:Graphics = d.graphicsOf(clip(t)); if (gr) gr.clear(); return undefined; });
			fn(cp, "lineStyle", function(t:*, a:Array):* {
				var gr:Graphics = d.graphicsOf(clip(t)); if (!gr) return undefined;
				if (a[0] === undefined) gr.lineStyle();
				else gr.lineStyle(num(a[0]), uint(num(a[1])), a.length > 2 && a[2] !== undefined ? num(a[2]) / 100 : 1);
				return undefined;
			});
			fn(cp, "beginFill", function(t:*, a:Array):* {
				var gr:Graphics = d.graphicsOf(clip(t)); if (!gr) return undefined;
				gr.beginFill(uint(num(a[0])), a.length > 1 && a[1] !== undefined ? num(a[1]) / 100 : 1);
				return undefined;
			});
			fn(cp, "beginGradientFill", function(t:*, a:Array):* { if (t is AClip) d.gradientFill(t, a); return undefined; });
			fn(cp, "endFill", function(t:*, a:Array):* { var gr:Graphics = d.graphicsOf(clip(t)); if (gr) gr.endFill(); return undefined; });
			fn(cp, "moveTo", function(t:*, a:Array):* { var gr:Graphics = d.graphicsOf(clip(t)); if (gr) gr.moveTo(num(a[0]), num(a[1])); return undefined; });
			fn(cp, "lineTo", function(t:*, a:Array):* { var gr:Graphics = d.graphicsOf(clip(t)); if (gr) gr.lineTo(num(a[0]), num(a[1])); return undefined; });
			fn(cp, "curveTo", function(t:*, a:Array):* { var gr:Graphics = d.graphicsOf(clip(t)); if (gr) gr.curveTo(num(a[0]), num(a[1]), num(a[2]), num(a[3])); return undefined; });
			ctor("MovieClip", cp, function(t:*, a:Array):* { return undefined; });

			vm.buttonProto = new AObject(op);
			fn(vm.buttonProto, "getDepth", function(t:*, a:Array):* { return t is AClip ? d.getDepth(t) : undefined; });
			fn(vm.buttonProto, "swapDepths", function(t:*, a:Array):* { if (t is AClip) d.swapDepths(t, a[0]); return undefined; });
			fn(vm.buttonProto, "toString", function(t:*, a:Array):* { return "[object Object]"; });
			ctor("Button", vm.buttonProto, function(t:*, a:Array):* { return undefined; });

			vm.textProto = new AObject(op);
			var tp:AObject = vm.textProto;
			fn(tp, "setTextFormat", function(t:*, a:Array):* {
				var tf:TextField = t is AClip ? (t as AClip).d as TextField : null;
				if (!tf) return undefined;
				var fmt:* = a[a.length - 1];
				var f:TextFormat = toTextFormat(fmt);
				if (!f) return undefined;
				try
				{
					if (a.length >= 3) tf.setTextFormat(f, int(num(a[0])), int(num(a[1])));
					else if (a.length == 2) tf.setTextFormat(f, int(num(a[0])), int(num(a[0])) + 1);
					else tf.setTextFormat(f);
				}
				catch (e:Error) {}
				return undefined;
			});
			fn(tp, "setNewTextFormat", function(t:*, a:Array):* {
				var tf:TextField = t is AClip ? (t as AClip).d as TextField : null;
				var f:TextFormat = toTextFormat(a[0]);
				if (tf && f) tf.defaultTextFormat = f;
				return undefined;
			});
			fn(tp, "getTextFormat", function(t:*, a:Array):* { return makeTextFormat([]); });
			fn(tp, "getNewTextFormat", function(t:*, a:Array):* { return makeTextFormat([]); });
			fn(tp, "replaceSel", function(t:*, a:Array):* {
				var tf:TextField = t is AClip ? (t as AClip).d as TextField : null;
				if (tf) tf.replaceSelectedText(str(a[0]));
				return undefined;
			});
			fn(tp, "removeTextField", function(t:*, a:Array):* { if (t is AClip) d.remove(t); return undefined; });
			fn(tp, "getDepth", function(t:*, a:Array):* { return t is AClip ? d.getDepth(t) : undefined; });
			fn(tp, "swapDepths", function(t:*, a:Array):* { if (t is AClip) d.swapDepths(t, a[0]); return undefined; });
			fn(tp, "toString", function(t:*, a:Array):* { return str(t); });
			var tfCtor:ANative = ctor("TextField", tp, function(t:*, a:Array):* { return undefined; });
			fn(tfCtor, "getFontList", function(t:*, a:Array):* { return ["_sans", "_serif", "_typewriter"]; });
		}

		private function frameArg(a:Array):*
		{
			var f:* = a[0];
			if (f is String) return f;
			return int(num(f));
		}

		private function makeTextFormat(a:Array):*
		{
			var o:AObject = vm.newObject();
			var names:Array = ["font", "size", "color", "bold", "italic", "underline", "url", "target", "align",
				"leftMargin", "rightMargin", "indent", "leading"];
			for (var i:int = 0; i < names.length; i++) vm.objSet(o, names[i], i < a.length ? a[i] : null);
			return o;
		}

		private function toTextFormat(o:*):TextFormat
		{
			if (!(o is AObject)) return null;
			var f:TextFormat = new TextFormat();
			var g:Function = function(n:String):* { var v:* = vm.getMember(o, n); return v === null ? undefined : v; };
			if (g("font") !== undefined) f.font = str(g("font"));
			if (g("size") !== undefined) f.size = num(g("size"));
			if (g("color") !== undefined) f.color = uint(num(g("color")));
			if (g("bold") !== undefined) f.bold = vm.toBoolean(g("bold"));
			if (g("italic") !== undefined) f.italic = vm.toBoolean(g("italic"));
			if (g("underline") !== undefined) f.underline = vm.toBoolean(g("underline"));
			if (g("align") !== undefined) f.align = str(g("align"));
			if (g("leftMargin") !== undefined) f.leftMargin = num(g("leftMargin"));
			if (g("rightMargin") !== undefined) f.rightMargin = num(g("rightMargin"));
			if (g("indent") !== undefined) f.indent = num(g("indent"));
			if (g("leading") !== undefined) f.leading = num(g("leading"));
			return f;
		}

		// ================================================================= Sound

		private function setupSound(op:AObject):void
		{
			vm.soundProto = new AObject(op);
			var p:AObject = vm.soundProto;
			ctor("Sound", p, function(t:*, a:Array):* { return undefined; }, function(a:Array):* {
				var o:AObject = new AObject(p);
				sounds[o] = { target: a[0] is AClip ? a[0] : null, snd: null, ch: null, vol: 100, pan: 0, pos: 0 };
				return o;
			});
			fn(p, "attachSound", function(t:*, a:Array):* {
				var s:Object = sounds[t]; if (!s) return undefined;
				var id:int = vm.data.exportId(str(a[0]));
				s.snd = id >= 0 ? vm.display.newSound(id) : null;
				s.name = str(a[0]);
				if (!s.snd) vm.warnOnce("attachSound: no sound \"" + str(a[0]) + "\"");
				return undefined;
			});
			fn(p, "start", function(t:*, a:Array):* {
				var s:Object = sounds[t]; if (!s || !s.snd || vm.dead) return undefined;
				var offset:Number = num(a[0]); if (isNaN(offset)) offset = 0;
				var loops:int = int(num(a[1])); if (loops < 1) loops = 1;
				if (vm.debug && soundLogs++ < 40) vm.log("avm1: sound " + s.name + ".start(" + offset + ", " + loops + ")");
				var self:* = t;
				var v:Voice = mixer.play(s.snd as Sound, offset * 1000, loops, s.vol, s.pan);
				if (vm.debug && soundLogs < 40) vm.log("avm1: sound " + s.name + (v ? " mixed (" + v.data.length + " bytes pcm)" : " played by AIR"));
				if (v) { v.owner = self; s.ch = v; return undefined; }
				try
				{
					makeRoom(s.snd);
					var ch:SoundChannel = (s.snd as Sound).play(offset * 1000, loops, new SoundTransform(s.vol / 100, s.pan / 100));
					s.ch = ch;
					if (ch)
					{
						channels.push({ ch: ch, snd: s.snd });
						ch.addEventListener(Event.SOUND_COMPLETE, function(e:Event):void { forget(e.target as SoundChannel); });
					}
					if (ch)
					{
						ch.addEventListener(Event.SOUND_COMPLETE, function(e:Event):void {
							var f:* = vm.getMember(self, "onSoundComplete");
							if (vm.isFunc(f)) vm.callHandler(f, self, []);
						});
					}
				}
				catch (e:Error) {}
				return undefined;
			});
			fn(p, "stop", function(t:*, a:Array):* {
				var s:Object = sounds[t]; if (!s) return undefined;
				if (s.ch) { s.pos = s.ch.position; s.ch.stop(); s.ch = null; }
				else if (!s.snd) { SoundMixer.stopAll(); clearChannels(); }
				return undefined;
			});
			fn(p, "setVolume", function(t:*, a:Array):* {
				var s:Object = sounds[t]; if (!s) return undefined;
				s.vol = num(a[0]);
				if (s.ch) setLevel(s);
				else if (!s.snd) vm.display.setVolume(s.target, s.vol);
				return undefined;
			});
			fn(p, "getVolume", function(t:*, a:Array):* { var s:Object = sounds[t]; return s ? s.vol : 100; });
			fn(p, "setPan", function(t:*, a:Array):* {
				var s:Object = sounds[t]; if (!s) return undefined;
				s.pan = num(a[0]);
				if (s.ch) setLevel(s);
				return undefined;
			});
			fn(p, "getPan", function(t:*, a:Array):* { var s:Object = sounds[t]; return s ? s.pan : 0; });
			fn(p, "setTransform", function(t:*, a:Array):* { return undefined; });
			fn(p, "getTransform", function(t:*, a:Array):* { return vm.newObject(); });
			fn(p, "loadSound", function(t:*, a:Array):* { vm.warnOnce("loadSound isn't supported"); return undefined; });
			fn(p, "getBytesLoaded", function(t:*, a:Array):* { return 100; });
			fn(p, "getBytesTotal", function(t:*, a:Array):* { return 100; });
			p.setAccessor(vm.key("position"), vm.nat("position", function(t:*, a:Array):* {
				var s:Object = sounds[t];
				return s && s.ch ? Math.round(s.ch.position) : (s ? s.pos : 0);
			}), null);
			p.setAccessor(vm.key("duration"), vm.nat("duration", function(t:*, a:Array):* {
				var s:Object = sounds[t];
				return s && s.snd ? Math.round((s.snd as Sound).length) : 0;
			}), null);
		}

		// ================================================================= Color

		private function setupColor(op:AObject):void
		{
			vm.colorProto = new AObject(op);
			var p:AObject = vm.colorProto;
			ctor("Color", p, function(t:*, a:Array):* { return undefined; }, function(a:Array):* {
				var o:AObject = new AObject(p);
				colors[o] = a[0] is AClip ? a[0] : (a[0] is String ? vm.targetClip(vm.display.ctxFor(vm.display.rootClip), a[0]) : null);
				return o;
			});
			fn(p, "setRGB", function(t:*, a:Array):* { vm.display.setRGB(colors[t], uint(num(a[0]))); return undefined; });
			fn(p, "getRGB", function(t:*, a:Array):* { return vm.display.getRGB(colors[t]); });
			fn(p, "setTransform", function(t:*, a:Array):* { vm.display.setColorTransform(colors[t], a[0]); return undefined; });
			fn(p, "getTransform", function(t:*, a:Array):* { return vm.display.getColorTransform(colors[t]); });
		}

		// ================================================================= constructors

		private function makeArray(a:Array):*
		{
			if (a.length == 1 && a[0] is Number)
			{
				var r:Array = [];
				r.length = int(a[0]);
				return r;
			}
			return a.concat();
		}

		private function makeDate(a:Array):*
		{
			if (a.length == 0) return new Date();
			if (a.length == 1) return new Date(num(a[0]));
			var n:Array = [];
			for each (var x:* in a) n.push(num(x));
			while (n.length < 7) n.push(n.length == 2 ? 1 : 0);
			return new Date(n[0], n[1], n[2], n[3], n[4], n[5], n[6]);
		}

		private function dateMethod(name:String):Function
		{
			return function(t:*, a:Array):* {
				if (!(t is Date)) return undefined;
				var args:Array = [];
				for each (var x:* in a) args.push(num(x));
				return (t as Date)[name].apply(t, args);
			};
		}

		private function mathFn(name:String):Function
		{
			return function(t:*, a:Array):* {
				var args:Array = [];
				for each (var x:* in a) args.push(num(x));
				return Math[name].apply(null, args);
			};
		}

		/** new X() where X isn't defined */
		public function constructByName(name:String, args:Array):*
		{
			if (name == "LocalConnection")
			{
				// talking to other Flash movies (Wii remote helpers, high-score boxes): there are none
				var lc:AObject = vm.newObject();
				fn(lc, "connect", function(t:*, a:Array):* { return false; });
				fn(lc, "send", function(t:*, a:Array):* { return false; });
				fn(lc, "close", function(t:*, a:Array):* { return undefined; });
				fn(lc, "domain", function(t:*, a:Array):* { return "localhost"; });
				return lc;
			}
			vm.warnOnce("new " + name + ": not supported");
			return vm.newObject();
		}

		/** f(...) where f isn't a defined function */
		public function callGlobal(c:Ctx, name:String, args:Array):*
		{
			// a MovieClip method called without an object (inside with() / tellTarget):
			// run it on the innermost clip of the scope chain
			var m:* = vm.objGet(vm.clipProto, name);
			var where:Array = [];
			for each (var sc:* in c.scope) where.push(sc is AClip ? vm.display.targetPath(sc, true) + ((sc as AClip).proto == vm.clipProto ? "" : "(no MovieClip methods)") : vm.typeOf(sc));
			vm.warnOnce("function " + name + "() not found in scope [" + where.join(", ") + "]" + (vm.isFunc(m) ? ", calling it on the clip" : ""));
			var clipObj:AClip = null;
			for (var i:int = c.scope.length - 1; i >= 0 && !clipObj; i--) clipObj = c.scope[i] as AClip;
			if (!clipObj) clipObj = c.target;
			if (vm.isFunc(m)) return vm.call(m, clipObj, args);
			// last resort: the timeline commands, straight to the display
			var d:VmDisplay = vm.display;
			switch (name.toLowerCase())
			{
				case "play": d.play(clipObj); break;
				case "stop": d.stop(clipObj); break;
				case "nextframe": d.nextFrame(clipObj); break;
				case "prevframe": d.prevFrame(clipObj); break;
				case "gotoandplay": d.gotoFrame(clipObj, frameArg(args), true); break;
				case "gotoandstop": d.gotoFrame(clipObj, frameArg(args), false); break;
			}
			return undefined;
		}

		/**
		 * fn(url, target): the game sends its own page to another page of its site (arcade games do
		 * that after "submitting score": the site saves it and shows the game again). Set by the player.
		 */
		public var onNavigate:Function;
		private static const CLOSE_JS:RegExp = /^javascript:\s*((window|self|top|parent)\.)?close\s*\(\s*\)/i;
		/** fn(): the game closes itself (an "Exit" button). Set by the player. */
		public var onQuit:Function;

		public function getURL(c:Ctx, url:String, target:String):void
		{
			// "Exit" buttons: fscommand("quit") or getURL("javascript:window.close()") close the player
			var quit:Boolean;
			if (url.indexOf("FSCommand:") == 0) quit = url.substr(10).toLowerCase() == "quit";
			else quit = CLOSE_JS.test(url);
			if (quit && onQuit != null)
			{
				vm.log("avm1: " + url + ": the game closes itself");
				onQuit();
				return;
			}
			if (url.indexOf("FSCommand:") == 0) return;
			var t:String = (target || "").toLowerCase();
			var samePage:Boolean = t == "" || t == "_self" || t == "_top" || t == "_parent";
			var relative:Boolean = url != "" && !/^[a-z][a-z0-9+.\-]*:/i.test(url) && url.charAt(0) != "#";
			if (samePage && relative && onNavigate != null)
			{
				vm.log("avm1: getURL " + url.substr(0, 60) + " (" + (target || "_self") + "): the game leaves its page");
				onNavigate(url, target);
				return;
			}
			vm.warnOnce("getURL ignored: " + url.substr(0, 60));
		}

		public function getURL2(c:Ctx, url:String, target:*, method:int):void
		{
			if (method & 0x40)
			{
				// unloadMovie(target) is a loadMovie of ""
				if (url == "") { var tc:AClip = vm.targetClip(c, target); if (tc) vm.display.unload(tc); return; }
				vm.warnOnce("loadMovie isn't supported: " + url.substr(0, 60));
				return;
			}
			if (method & 0x80) return; // loadVariables
			getURL(c, url, vm.toStr(target));
		}

		// ================================================================= keys / mouse

		public function isDown(code:int):Boolean
		{
			return keys[code] == true;
		}

		public function setKey(code:int, ascii:int, down:Boolean):void
		{
			keys[code] = down;
			if (down)
			{
				lastKey = code;
				lastAscii = ascii;
			}
		}

		public function keyEvent(name:String):void
		{
			for each (var l:* in keyListeners.concat())
			{
				var f:* = vm.getMember(l, name);
				if (vm.isFunc(f)) vm.callHandler(f, l, []);
			}
		}

		public function mouseEvent(name:String):void
		{
			for each (var l:* in mouseListeners.concat())
			{
				var f:* = vm.getMember(l, name);
				if (vm.isFunc(f)) vm.callHandler(f, l, []);
			}
		}

		// ================================================================= intervals

		private function addInterval(a:Array, repeat:Boolean):int
		{
			var f:*, thisObj:*, ms:Number, args:Array;
			if (vm.isFunc(a[0]))
			{
				f = a[0];
				thisObj = undefined;
				ms = num(a[1]);
				args = a.slice(2);
			}
			else
			{
				thisObj = a[0];
				f = str(a[1]);
				ms = num(a[2]);
				args = a.slice(3);
			}
			if (isNaN(ms) || ms < 1) ms = 1;
			var id:int = nextInterval++;
			var t:Timer = new Timer(ms, repeat ? 0 : 1);
			t.addEventListener(TimerEvent.TIMER, function(e:TimerEvent):void {
				if (vm.display.paused) return;
				var fn2:* = f is String ? vm.getMember(thisObj, f) : f;
				if (vm.isFunc(fn2)) vm.callHandler(fn2, thisObj, args);
				if (!repeat) delete intervals[id];
			});
			intervals[id] = t;
			t.start();
			return id;
		}

		private function clearTimer(id:int):void
		{
			var t:Timer = intervals[id];
			if (!t) return;
			t.stop();
			delete intervals[id];
		}

		/**
		 * Android's mixer has few voices: dozens of overlapping copies of one sound (a shot
		 * fired on every tap) can jam it into an endless loop that outlives the game. Keep at
		 * most 4 copies of a sound and 12 sounds in all; the oldest ones give way.
		 */
		private static const MAX_SAME:int = 4;
		private static const MAX_ALL:int = 12;

		private function makeRoom(snd:Object):void
		{
			var same:int = 0;
			for each (var r:Object in channels) if (r.snd == snd) same++;
			var i:int = 0;
			while (same >= MAX_SAME && i < channels.length)
			{
				if (channels[i].snd == snd) { stopRec(channels[i]); channels.splice(i, 1); same--; }
				else i++;
			}
			while (channels.length >= MAX_ALL) stopRec(channels.shift());
		}

		private function stopRec(r:Object):void
		{
			try { (r.ch as SoundChannel).stop(); } catch (e:Error) {}
		}

		private function forget(ch:SoundChannel):void
		{
			for (var i:int = 0; i < channels.length; i++)
			{
				if (channels[i].ch == ch) { channels.splice(i, 1); return; }
			}
		}

		private function setLevel(s:Object):void
		{
			if (s.ch is Voice) (s.ch as Voice).setLevel(s.vol, s.pan);
			else if (s.ch is SoundChannel) (s.ch as SoundChannel).soundTransform = new SoundTransform(s.vol / 100, s.pan / 100);
		}

		/** sounds started from code are mixed into one channel (see SoftMixer) */
		private var _mixer:SoftMixer;

		private function get mixer():SoftMixer
		{
			if (!_mixer)
			{
				_mixer = new SoftMixer();
				_mixer.onComplete = function(v:Voice):void {
					if (vm.dead || v.owner === undefined) return;
					var f:* = vm.getMember(v.owner, "onSoundComplete");
					if (vm.isFunc(f)) vm.callHandler(f, v.owner, []);
				};
			}
			return _mixer;
		}

		private var timelineSnd:Object = {};

		/** a StartSound of the timeline (SwfConvert moved it here so all sound goes through one mixer) */
		public function timelineSound(rec:Object):void
		{
			if (vm.dead || !rec) return;
			var snd:Sound = timelineSnd[rec.id] as Sound;
			if (!snd)
			{
				snd = vm.display.newSound(rec.id) as Sound;
				if (!snd) return;
				timelineSnd[rec.id] = snd;
			}
			if (rec.stop) { mixer.stopSound(snd); stopNative(snd); return; }
			if (rec.single && (mixer.isPlaying(snd) || nativePlaying(snd))) return;
			var v:Voice = mixer.play(snd, rec.inMs, rec.loops, 100, 0);
			if (vm.debug && soundLogs++ < 40) vm.log("avm1: timeline sound " + rec.id + (v ? " mixed" : " played by AIR") +
				(rec.env ? ", envelope " + rec.env.join(",") : "") + (rec.outMs ? ", out " + Math.round(rec.outMs) + " ms" : ""));
			if (v)
			{
				v.startPos = v.pos;
				if (rec.outMs > 0) v.endPos = int(rec.outMs * 44.1) * 8;
				v.env = rec.env;
				return;
			}
			try
			{
				makeRoom(snd);
				var st:SoundTransform = null;
				if (rec.env) st = new SoundTransform(Math.max(rec.env[1], rec.env[2]), envPan(rec.env[1], rec.env[2]));
				var ch:SoundChannel = snd.play(rec.inMs, rec.loops, st);
				if (ch)
				{
					var cr:Object = { ch: ch, snd: snd };
					channels.push(cr);
					ch.addEventListener(Event.SOUND_COMPLETE, function(e:Event):void { forget(e.target as SoundChannel); });
					if (rec.env || rec.outMs > 0) watchChannel(cr, rec);
				}
			}
			catch (e:Error) {}
		}

		// long sounds AIR plays itself: envelope and end point applied a few times a second
		private var watched:Array = [];
		private var watchTimer:Timer;

		private static function envPan(l:Number, r:Number):Number
		{
			var m:Number = Math.max(l, r);
			return m > 0 ? (r - l) / m : 0;
		}

		private function watchChannel(cr:Object, rec:Object):void
		{
			var voice:Voice = new Voice();
			voice.env = rec.env;
			watched.push({ cr: cr, v: voice, t0: getTimer(), outMs: rec.outMs, loopMs: rec.outMs > rec.inMs && rec.loops <= 1 ? rec.outMs - rec.inMs : 0, loops: 1 });
			if (!watchTimer)
			{
				watchTimer = new Timer(50);
				watchTimer.addEventListener(TimerEvent.TIMER, onWatch);
			}
			if (!watchTimer.running) watchTimer.start();
		}

		private function onWatch(e:TimerEvent):void
		{
			for (var i:int = watched.length - 1; i >= 0; i--)
			{
				var w:Object = watched[i];
				var ch:SoundChannel = w.cr.ch as SoundChannel;
				if (vm.dead || channels.indexOf(w.cr) < 0) { watched.splice(i, 1); continue; }
				var ms:Number = getTimer() - w.t0;
				try
				{
					if (w.loopMs > 0 && ms >= w.loopMs * w.loops)
					{
						ch.stop();
						forget(ch);
						watched.splice(i, 1);
						continue;
					}
					if (w.v.env)
					{
						w.v.envAt(ms * 44.1);
						ch.soundTransform = new SoundTransform(Math.max(w.v.envL, w.v.envR), envPan(w.v.envL, w.v.envR));
					}
				}
				catch (err:Error) { watched.splice(i, 1); }
			}
			if (!watched.length && watchTimer) watchTimer.stop();
		}

		private function nativePlaying(snd:Object):Boolean
		{
			for each (var r:Object in channels) if (r.snd == snd) return true;
			return false;
		}

		private function stopNative(snd:Object):void
		{
			for (var i:int = channels.length - 1; i >= 0; i--)
			{
				if (channels[i].snd == snd) { stopRec(channels[i]); channels.splice(i, 1); }
			}
		}

		/** stopAllSounds / Sound.stop() without a sound: our channels are gone too */
		public function clearChannels():void
		{
			if (_mixer) _mixer.stopAll();
			for each (var r:Object in channels) stopRec(r);
			channels = [];
		}

		public function dispose():void
		{
			for each (var cr:Object in channels) try { (cr.ch as SoundChannel).stop(); } catch (e0:Error) {}
			channels = [];
			watched = [];
			if (watchTimer) { watchTimer.stop(); watchTimer.removeEventListener(TimerEvent.TIMER, onWatch); watchTimer = null; }
			if (_mixer) { _mixer.dispose(); _mixer = null; }
			for (var k:String in intervals) (intervals[k] as Timer).stop();
			intervals = {};
			for (var s:* in sounds)
			{
				var o:Object = sounds[s];
				if (o && o.ch) try { (o.ch as SoundChannel).stop(); } catch (e:Error) {}
			}
		}

		// ================================================================= SharedObject (save games)

		private var shared:Object = {};

		/** write every SharedObject this game opened (old games often never call flush) */
		public function flushAll():int
		{
			var n:int = 0;
			if (!storage || storage.save == null) return 0;
			for (var name:String in shared)
			{
				try
				{
					storage.save(name, JSON.stringify(toPlain(vm.getMember(shared[name], "data"), 0)));
					n++;
				}
				catch (e:Error) {}
			}
			return n;
		}

		private function sharedObject(name:String):AObject
		{
			if (shared[name]) return shared[name];
			var so:AObject = vm.newObject();
			var data:AObject = vm.newObject();
			if (storage && storage.load != null)
			{
				try
				{
					var json:String = storage.load(name);
					if (json) data = fromPlain(JSON.parse(json)) as AObject || data;
				}
				catch (e:Error) {}
			}
			vm.objSet(so, "data", data);
			fn(so, "flush", function(t:*, a:Array):* {
				if (storage && storage.save != null)
				{
					try { storage.save(name, JSON.stringify(toPlain(vm.getMember(so, "data"), 0))); } catch (e:Error) {}
				}
				return true;
			});
			fn(so, "clear", function(t:*, a:Array):* { vm.objSet(so, "data", vm.newObject()); return undefined; });
			fn(so, "getSize", function(t:*, a:Array):* { return 0; });
			shared[name] = so;
			return so;
		}

		private function toPlain(v:*, depth:int):*
		{
			if (depth > 20) return null;
			if (v is AClip || vm.isFunc(v)) return null;
			if (v is Array)
			{
				var r:Array = [];
				for each (var e:* in v) r.push(toPlain(e, depth + 1));
				return r;
			}
			if (v is AObject)
			{
				var o:Object = {};
				for each (var k:String in vm.enumerate(v)) o[k] = toPlain(vm.getMember(v, k), depth + 1);
				return o;
			}
			if (v === undefined) return null;
			return v;
		}

		private function fromPlain(v:*):*
		{
			if (v is Array)
			{
				var r:Array = [];
				for each (var e:* in v) r.push(fromPlain(e));
				return r;
			}
			if (v !== null && typeof v == "object")
			{
				var o:AObject = vm.newObject();
				for (var k:String in v) vm.objSet(o, k, fromPlain(v[k]));
				return o;
			}
			return v;
		}
	}
}
