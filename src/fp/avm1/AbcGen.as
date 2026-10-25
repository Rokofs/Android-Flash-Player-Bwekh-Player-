package fp.avm1
{
	import flash.utils.ByteArray;
	import flash.utils.Endian;

	/**
	 * Writes a tiny ABC (ActionScript 3 bytecode) block with one empty class per library symbol:
	 *   fp_s_<id> extends flash.display.MovieClip   (sprites)
	 *   fp_b_<id> extends flash.display.SimpleButton (buttons)
	 *   fp_a_<id> extends flash.media.Sound          (sounds)
	 * Linked with SymbolClass, they let the AVM1 engine tell which symbol an instance is and
	 * create new instances (attachMovie, duplicateMovieClip, Sound.attachSound).
	 * The bytecode follows what the Flex compiler emits for such classes.
	 */
	public class AbcGen
	{
		public static const SPRITE:String = "fp_s_";
		public static const BUTTON:String = "fp_b_";
		public static const SOUND:String = "fp_a_";
		/** fonts: registered with Font.registerFont so text fields made by code can use them */
		public static const FONT:String = "fp_f_";

		private var strings:Array = [];
		private var stringIndex:Object = {};
		private var namespaces:Array = [];   // [string index]
		private var nsIndex:Object = {};
		private var multinames:Array = [];   // [ns index, name index]
		private var mnIndex:Object = {};

		private static const CHAINS:Object = {
			"fp_s_": [["", "Object"], ["flash.events", "EventDispatcher"], ["flash.display", "DisplayObject"],
				["flash.display", "InteractiveObject"], ["flash.display", "DisplayObjectContainer"],
				["flash.display", "Sprite"], ["flash.display", "MovieClip"]],
			"fp_b_": [["", "Object"], ["flash.events", "EventDispatcher"], ["flash.display", "DisplayObject"],
				["flash.display", "InteractiveObject"], ["flash.display", "SimpleButton"]],
			"fp_a_": [["", "Object"], ["flash.events", "EventDispatcher"], ["flash.media", "Sound"]],
			"fp_f_": [["", "Object"], ["flash.text", "Font"]]
		};

		/** classes: Array of class names (prefix + id). Returns the ABC bytes. */
		public static function build(classes:Array):ByteArray
		{
			return new AbcGen().make(classes);
		}

		private function str(s:String):int
		{
			if (stringIndex[s] !== undefined) return stringIndex[s];
			strings.push(s);
			stringIndex[s] = strings.length; // index 0 is reserved
			return strings.length;
		}

		private function ns(pkg:String):int
		{
			if (nsIndex[pkg] !== undefined) return nsIndex[pkg];
			namespaces.push(str(pkg));
			nsIndex[pkg] = namespaces.length;
			return namespaces.length;
		}

		private function qname(pkg:String, name:String):int
		{
			var k:String = pkg + "::" + name;
			if (mnIndex[k] !== undefined) return mnIndex[k];
			multinames.push([ns(pkg), str(name)]);
			mnIndex[k] = multinames.length;
			return multinames.length;
		}

		private function make(classes:Array):ByteArray
		{
			// methods: per class iinit + cinit, then one script init
			var n:int = classes.length;
			var classMn:Array = [];
			var chains:Array = [];
			for each (var c:String in classes)
			{
				classMn.push(qname("", c));
				var chain:Array = CHAINS[c.substr(0, 5)];
				var mns:Array = [];
				for each (var e:Array in chain) mns.push(qname(e[0], e[1]));
				chains.push(mns);
			}

			var out:ByteArray = new ByteArray();
			out.endian = Endian.LITTLE_ENDIAN;
			out.writeShort(16); // minor
			out.writeShort(46); // major

			// constant pool
			u30(out, 0); // ints
			u30(out, 0); // uints
			u30(out, 0); // doubles
			u30(out, strings.length + 1);
			for each (var s:String in strings)
			{
				var b:ByteArray = new ByteArray();
				b.writeUTFBytes(s);
				u30(out, b.length);
				out.writeBytes(b);
			}
			u30(out, namespaces.length + 1);
			for each (var nsName:int in namespaces)
			{
				out.writeByte(0x16); // PackageNamespace
				u30(out, nsName);
			}
			u30(out, 0); // ns sets
			u30(out, multinames.length + 1);
			for each (var mn:Array in multinames)
			{
				out.writeByte(0x07); // QName
				u30(out, mn[0]);
				u30(out, mn[1]);
			}

			// method infos: 2 per class + script init
			var methodCount:int = n * 2 + 1;
			u30(out, methodCount);
			for (var m:int = 0; m < methodCount; m++)
			{
				u30(out, 0); // params
				u30(out, 0); // return type *
				u30(out, 0); // name
				out.writeByte(0); // flags
			}
			u30(out, 0); // metadata

			// instances
			u30(out, n);
			for (var i:int = 0; i < n; i++)
			{
				u30(out, classMn[i]);
				var ch:Array = chains[i];
				u30(out, ch[ch.length - 1]); // super
				out.writeByte(0);          // dynamic, no protected namespace
				u30(out, 0);               // interfaces
				u30(out, i * 2);           // iinit
				u30(out, 0);               // traits
			}
			// classes
			for (i = 0; i < n; i++)
			{
				u30(out, i * 2 + 1); // cinit
				u30(out, 0);
			}
			// one script defining all classes
			u30(out, 1);
			u30(out, n * 2); // init method
			u30(out, n);
			for (i = 0; i < n; i++)
			{
				u30(out, classMn[i]);
				out.writeByte(4); // Class trait
				u30(out, 0);      // slot id: automatic
				u30(out, i);      // class index
			}

			// method bodies
			u30(out, methodCount);
			var maxChain:int = 0;
			for (i = 0; i < n; i++)
			{
				var k:int = chains[i].length;
				if (k > maxChain) maxChain = k;
				// iinit: this.super()
				body(out, i * 2, 1, 1, k + 3, k + 4, [0xD0, 0x30, 0xD0, 0x49, 0x00, 0x47]);
				// cinit: nothing
				body(out, i * 2 + 1, 1, 1, k + 2, k + 3, [0xD0, 0x30, 0x47]);
			}
			// script init: for each class: findpropstrict C; push base chain scopes; getlex base;
			// newclass i; popscope x k; initproperty C
			var code:ByteArray = new ByteArray();
			code.writeByte(0xD0); // getlocal0
			code.writeByte(0x30); // pushscope
			for (i = 0; i < n; i++)
			{
				var chainI:Array = chains[i];
				code.writeByte(0x5D); u30(code, classMn[i]);  // findpropstrict
				for each (var sm:int in chainI)
				{
					code.writeByte(0x60); u30(code, sm);       // getlex
					code.writeByte(0x30);                       // pushscope
				}
				code.writeByte(0x60); u30(code, chainI[chainI.length - 1]); // getlex base
				code.writeByte(0x58); u30(code, i);                          // newclass
				for (var p:int = 0; p < chainI.length; p++) code.writeByte(0x1D); // popscope
				code.writeByte(0x68); u30(code, classMn[i]);                 // initproperty
			}
			code.writeByte(0x47); // returnvoid
			var codeArr:Array = [];
			for (var q:int = 0; q < code.length; q++) codeArr.push(code[q]);
			body(out, n * 2, 2, 1, 1, maxChain + 2, codeArr);

			out.position = 0;
			return out;
		}

		private static function body(out:ByteArray, method:int, maxStack:int, locals:int,
		                             initScope:int, maxScope:int, code:Array):void
		{
			u30(out, method);
			u30(out, maxStack);
			u30(out, locals);
			u30(out, initScope);
			u30(out, maxScope);
			u30(out, code.length);
			for each (var b:int in code) out.writeByte(b);
			u30(out, 0); // exceptions
			u30(out, 0); // traits
		}

		private static function u30(out:ByteArray, v:uint):void
		{
			do
			{
				var b:int = v & 0x7F;
				v >>>= 7;
				if (v != 0) b |= 0x80;
				out.writeByte(b);
			}
			while (v != 0);
		}

		/** DoABC tag body (flags + name + abc). */
		public static function doAbcTag(abc:ByteArray):ByteArray
		{
			var t:ByteArray = new ByteArray();
			t.endian = Endian.LITTLE_ENDIAN;
			t.writeUnsignedInt(1); // lazy initialize
			t.writeUTFBytes("fpavm1");
			t.writeByte(0);
			t.writeBytes(abc);
			return t;
		}

		/** SymbolClass tag body: [[charId, className], ...] */
		public static function symbolClassTag(pairs:Array):ByteArray
		{
			var t:ByteArray = new ByteArray();
			t.endian = Endian.LITTLE_ENDIAN;
			t.writeShort(pairs.length);
			for each (var p:Array in pairs)
			{
				t.writeShort(p[0]);
				t.writeUTFBytes(p[1]);
				t.writeByte(0);
			}
			return t;
		}
	}
}
