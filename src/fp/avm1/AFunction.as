package fp.avm1
{
	import flash.utils.ByteArray;

	/** A function written in AS1/AS2 (DefineFunction / DefineFunction2). */
	public class AFunction extends AObject
	{
		public var name:String = "";
		public var code:ByteArray;
		public var start:int;
		public var end:int;
		/** DefineFunction: parameter names. DefineFunction2: [{reg, name}] */
		public var params:Array = [];
		public var df2:Boolean = false;
		public var regCount:int = 4;
		public var flags:int = 0;
		public var scope:Array;
		public var pool:Array;
		public var target:AClip;
		public var version:int = 6;

		public function AFunction(proto:AObject)
		{
			super(proto);
			kind = "function";
		}
	}
}
