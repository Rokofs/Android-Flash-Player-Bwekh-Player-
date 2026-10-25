package fp.avm1
{
	/** The "super" object inside a method: members come from proto, calls run with thisObj. */
	public class ASuper
	{
		public var thisObj:*;
		public var proto:AObject;
		public var ctor:*;

		public function ASuper(thisObj:*, proto:AObject, ctor:*)
		{
			this.thisObj = thisObj;
			this.proto = proto;
			this.ctor = ctor;
		}
	}
}
