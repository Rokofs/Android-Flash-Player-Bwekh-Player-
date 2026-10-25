package fp.avm1
{
	/** A built-in function. fn(thisObj, args:Array):*. ctor(args:Array):* when used with new. */
	public class ANative extends AObject
	{
		public var name:String;
		public var fn:Function;
		public var ctor:Function;

		public function ANative(proto:AObject, name:String, fn:Function, ctor:Function = null)
		{
			super(proto);
			this.name = name;
			this.fn = fn;
			this.ctor = ctor;
			kind = "function";
		}
	}
}
