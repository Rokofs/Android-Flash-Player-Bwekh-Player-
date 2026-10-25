package fp
{
	import flash.utils.ByteArray;
	import flash.utils.CompressionAlgorithm;
	import flash.utils.Endian;

	/** SWF container helpers that need nothing from AIR (also used by the desktop test harness). */
	public class SwfBytes
	{
		/** SWF bytes -> uncompressed body (everything after the 8-byte header). */
		public static function decompress(src:ByteArray):ByteArray
		{
			if (!src || src.length < 9) return null;
			src.position = 0;
			src.endian = Endian.LITTLE_ENDIAN;
			var sig:String = src.readUTFBytes(3);
			src.readUnsignedByte();
			var fileLength:uint = src.readUnsignedInt();
			var body:ByteArray = new ByteArray();
			if (sig == "FWS")
			{
				src.readBytes(body, 0, src.length - 8);
			}
			else if (sig == "CWS")
			{
				src.readBytes(body, 0, src.length - 8);
				body.uncompress(CompressionAlgorithm.ZLIB);
			}
			else if (sig == "ZWS")
			{
				src.readUnsignedInt();
				src.readBytes(body, 0, 5);
				body.position = 5;
				body.endian = Endian.LITTLE_ENDIAN;
				body.writeUnsignedInt(fileLength - 8);
				body.writeUnsignedInt(0);
				src.readBytes(body, 13);
				body.uncompress(CompressionAlgorithm.LZMA);
			}
			else
			{
				return null;
			}
			src.position = 0;
			body.endian = Endian.LITTLE_ENDIAN;
			return body;
		}
	}
}
