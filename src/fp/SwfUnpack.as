package fp
{
	import flash.filesystem.File;
	import flash.filesystem.FileMode;
	import flash.filesystem.FileStream;
	import flash.utils.ByteArray;
	import flash.utils.CompressionAlgorithm;
	import flash.utils.Endian;

	/**
	 * Many Flash games are a small preloader with the real game embedded as binary data
	 * ([Embed] -> DefineBinaryData) that it starts with Loader.loadBytes. AIR forbids that
	 * from loaded content (#3226), so we pull the embedded SWF out and load it ourselves.
	 * Also handles MochiCrypt: the payload is RC4-encrypted (key = its last 32 bytes, only the
	 * first 128 KB are encrypted) and then zlib-compressed.
	 */
	public class SwfUnpack
	{
		/** The largest SWF embedded in the file, or null. */
		public static function findInnerSwf(f:File):ByteArray
		{
			try
			{
				var src:ByteArray = new ByteArray();
				var fs:FileStream = new FileStream();
				fs.open(f, FileMode.READ);
				fs.readBytes(src);
				fs.close();
				var body:ByteArray = decompress(src);
				if (!body) return null;
				return scan(body);
			}
			catch (e:Error)
			{
				Log.error("unpack", e);
			}
			return null;
		}

		/** SWF bytes -> uncompressed body (everything after the 8-byte header). */
		public static function decompress(src:ByteArray):ByteArray
		{
			return SwfBytes.decompress(src);
		}

		private static function scan(b:ByteArray):ByteArray
		{
			// skip RECT, frame rate, frame count
			var nbits:int = b[0] >> 3;
			b.position = Math.ceil((5 + nbits * 4) / 8) + 4;
			var best:ByteArray = null;
			var biggestBlob:ByteArray = null;
			var guard:int = 0;
			while (b.bytesAvailable >= 2 && guard++ < 100000)
			{
				var header:uint = b.readUnsignedShort();
				var code:uint = header >> 6;
				var len:uint = header & 0x3F;
				if (len == 0x3F)
				{
					if (b.bytesAvailable < 4) break;
					len = b.readUnsignedInt();
				}
				var start:uint = b.position;
				if (start + len > b.length) break;
				if (code == 87 && len > 6 + 8) // DefineBinaryData: id(2) reserved(4) data
				{
					var data:ByteArray = new ByteArray();
					b.position = start + 6;
					b.readBytes(data, 0, len - 6);
					var swf:ByteArray = asSwf(data);
					if (swf && (!best || swf.length > best.length)) best = swf;
					if (!swf && (!biggestBlob || data.length > biggestBlob.length)) biggestBlob = data;
				}
				if (code == 0) break;
				b.position = start + len;
			}
			if (!best && biggestBlob && biggestBlob.length > 1024)
			{
				best = mochiDecrypt(biggestBlob);
				if (best) Log.write("unpack: MochiCrypt payload decrypted (" + best.length + " bytes)");
			}
			return best;
		}

		/** MochiCrypt preloader's algorithm. Returns the SWF or null if the blob isn't one. */
		public static function mochiDecrypt(src:ByteArray):ByteArray
		{
			try
			{
				var n:int = src.length - 32;
				if (n <= 0) return null;
				var S:Vector.<int> = new Vector.<int>(256, true);
				var i:int, j:int = 0, k:int, l:int;
				for (i = 0; i < 256; i++) S[i] = i;
				for (i = 0; i < 256; i++)
				{
					j = (j + S[i] + src[n + (i & 31)]) & 0xFF;
					k = S[i]; S[i] = S[j]; S[j] = k;
				}
				var out:ByteArray = new ByteArray();
				out.writeBytes(src, 0, n);
				var m:int = n > 131072 ? 131072 : n;
				i = 0;
				j = 0;
				for (l = 0; l < m; l++)
				{
					i = (i + 1) & 0xFF;
					j = (j + S[i]) & 0xFF;
					k = S[i]; S[i] = S[j]; S[j] = k;
					out[l] = out[l] ^ S[(S[i] + S[j]) & 0xFF];
				}
				if (out[0] != 0x78) return null; // not a zlib stream -> wrong guess
				out.uncompress(CompressionAlgorithm.ZLIB);
				return looksLikeSwf(out) ? out : null;
			}
			catch (e:Error)
			{
			}
			return null;
		}

		/** data if it is a SWF (or zlib-compressed SWF), else null. */
		private static function asSwf(d:ByteArray):ByteArray
		{
			if (looksLikeSwf(d)) return d;
			if (d.length > 2 && d[0] == 0x78) // zlib stream
			{
				try
				{
					var u:ByteArray = new ByteArray();
					u.writeBytes(d);
					u.uncompress(CompressionAlgorithm.ZLIB);
					if (looksLikeSwf(u)) return u;
				}
				catch (e:Error) {}
			}
			return null;
		}

		private static function looksLikeSwf(d:ByteArray):Boolean
		{
			if (d.length < 16) return false;
			var c0:int = d[0], c1:int = d[1], c2:int = d[2], ver:int = d[3];
			var sigOk:Boolean = (c0 == 0x46 || c0 == 0x43 || c0 == 0x5A) && c1 == 0x57 && c2 == 0x53; // F/C/Z "WS"
			return sigOk && ver >= 1 && ver <= 60;
		}
	}
}
