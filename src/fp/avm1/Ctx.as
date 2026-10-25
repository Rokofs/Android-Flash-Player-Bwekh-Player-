package fp.avm1
{
	/** Execution state of one piece of AS1/AS2 code (frame script, event, function call). */
	public class Ctx
	{
		public var stack:Array = [];
		public var regs:Array = [undefined, undefined, undefined, undefined];
		/** scope chain, outermost first: [_global, timeline, (with objects), activation] */
		public var scope:Array;
		public var thisObj:*;
		/** clip for timeline actions (play, gotoAndStop...) — changed by tellTarget */
		public var target:AClip;
		public var baseTarget:AClip;
		/** (replaced, never changed: a ConstantPool action sets a new one) */
		public var pool:Array = NO_POOL;
		public static const NO_POOL:Array = [];
		public var activation:AObject;
		public var func:AFunction;
		/** prototype the running method was found on (for super) */
		public var home:AObject;
		public var args:Array;
		/** the "arguments" object, made when the code first asks for it */
		public var argsCopy:Array;
		public var returned:Boolean = false;
		public var ret:*;
		public var version:int = 6;
	}
}
