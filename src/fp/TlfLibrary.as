package fp
{
	import flash.utils.ByteArray;
	import flash.utils.Endian;

	/**
	 * Text Layout Framework 1.0 (build 595), for Flash CS5 games with TLF text fields.
	 * Flash Pro loaded it at start from fpdownload.adobe.com as a signed RSL (textLayout_1.0.0.595.swz);
	 * that is gone (and Android blocks plain http), so the game stayed on a blank preloader.
	 * Built from Apache Flex TLF, branch 1.0 (the same build: kBuildNumber "595"), see
	 * tools/tlf/README.txt. The player loads it into the domain the game's domain is a child of.
	 */
	public class TlfLibrary
	{
		[Embed(source="assets/textLayout_1.0.0.595.swf", mimeType="application/octet-stream")]
		private static const LIB:Class;

		private static const RSL_URL:String = "http://fpdownload.adobe.com/pub/swz/tlf/";

		public static function get bytes():ByteArray
		{
			return new LIB() as ByteArray;
		}

		/** does this (uncompressed) SWF body load TLF as an RSL? */
		public static function needed(body:ByteArray):Boolean
		{
			return body != null && find(body, "textLayout_1.0.0.595") >= 0;
		}

		/**
		 * The same SWF with Adobe's address made unloadable (same length, so nothing else moves):
		 * the preloader fails at once instead of waiting on the network, and goes on with ours.
		 */
		public static function offline(swf:ByteArray):ByteArray
		{
			var body:ByteArray = SwfBytes.decompress(swf);
			if (!body) return null;
			var at:int = find(body, RSL_URL);
			if (at < 0) return null;
			while (at >= 0)
			{
				body[at] = 0x62; body[at + 1] = 0x77; body[at + 2] = 0x6B; body[at + 3] = 0x68; // "bwkh"
				at = find(body, RSL_URL, at + 1);
			}
			var out:ByteArray = new ByteArray();
			out.endian = Endian.LITTLE_ENDIAN;
			out.writeUTFBytes("FWS");
			out.writeByte(swf[3]);
			out.writeUnsignedInt(body.length + 8);
			out.writeBytes(body);
			out.position = 0;
			return out;
		}

		private static function find(b:ByteArray, s:String, from:int = 0):int
		{
			var n:int = s.length;
			var first:int = s.charCodeAt(0);
			var last:int = b.length - n;
			for (var i:int = from; i <= last; i++)
			{
				if (b[i] != first) continue;
				var j:int = 1;
				while (j < n && b[i + j] == s.charCodeAt(j)) j++;
				if (j == n) return i;
			}
			return -1;
		}
	}
}
