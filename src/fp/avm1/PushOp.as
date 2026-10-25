package fp.avm1
{
	/** A decoded Push action: kind 0 = the value itself, 1 = register number, 2 = constant pool index. */
	public final class PushOp
	{
		public var kinds:Vector.<int> = new Vector.<int>();
		public var vals:Array = [];

		public function add(kind:int, v:*):void
		{
			kinds.push(kind);
			vals.push(v);
		}
	}
}
