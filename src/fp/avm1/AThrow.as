package fp.avm1
{
	/** An AS1/AS2 "throw" travelling through the interpreter. */
	public class AThrow extends Error
	{
		public var value:*;

		public function AThrow(value:*)
		{
			super("AVM1 throw");
			this.value = value;
		}
	}
}
