package fp
{
	import flash.utils.ByteArray;
	import flash.utils.CompressionAlgorithm;
	import flash.utils.Endian;

	/**
	 * Читает заголовок SWF: размер сцены, частоту кадров, цвет фона
	 * и версию ActionScript (AS3 или AS1/AS2).
	 */
	public class SwfInfo
	{
		public var signatureOk:Boolean = false;
		public var parsed:Boolean = false;
		public var compression:String = "";
		public var version:int = 0;
		public var width:Number = 0;
		public var height:Number = 0;
		public var frameRate:Number = 0;
		public var frameCount:int = 0;
		public var isAS3:Boolean = false;
		public var bgColor:int = -1;
		/** the file's code mentions keyboard input (a game) — false for plain animations */
		public var usesKeys:Boolean = true;
		/** MochiCrypt-packed: the real game is encrypted inside (SwfUnpack can get it out) */
		public var packed:Boolean = false;
		/** video frames in the file (DefineVideoStream + VideoFrame): AIR on Android shows them black */
		public var hasVideo:Boolean = false;

		public static function parse(src:ByteArray):SwfInfo
		{
			var info:SwfInfo = new SwfInfo();
			if (src == null || src.length < 9) return info;

			src.position = 0;
			src.endian = Endian.LITTLE_ENDIAN;
			var sig:String = src.readUTFBytes(3);
			if (sig != "FWS" && sig != "CWS" && sig != "ZWS") return info;

			info.signatureOk = true;
			info.compression = sig;
			info.version = src.readUnsignedByte();
			var fileLength:uint = src.readUnsignedInt();
			// если разобрать теги не получится — угадываем по версии
			info.isAS3 = info.version >= 9;

			var body:ByteArray = new ByteArray();
			body.endian = Endian.LITTLE_ENDIAN;

			try
			{
				if (sig == "FWS")
				{
					src.readBytes(body, 0, src.length - 8);
				}
				else if (sig == "CWS")
				{
					src.readBytes(body, 0, src.length - 8);
					body.uncompress(CompressionAlgorithm.ZLIB);
				}
				else
				{
					// ZWS: [4 байта сжатая длина][5 байт свойства LZMA][данные]
					// ByteArray.uncompress(LZMA) ждёт стандартный .lzma-заголовок:
					// [5 байт свойства][8 байт исходная длина][данные]
					src.readUnsignedInt(); // длина сжатых данных — не нужна
					src.readBytes(body, 0, 5);
					body.position = 5;
					body.writeUnsignedInt(fileLength - 8);
					body.writeUnsignedInt(0);
					src.readBytes(body, 13);
					body.uncompress(CompressionAlgorithm.LZMA);
				}
				body.endian = Endian.LITTLE_ENDIAN;
				readBody(body, info);
				info.usesKeys = scanKeys(body, info);
				info.parsed = true;
			}
			catch (e:Error)
			{
				info.parsed = false;
			}

			src.position = 0;
			return info;
		}

		private static function readBody(b:ByteArray, info:SwfInfo):void
		{
			b.position = 0;

			// RECT: 5 бит — размер полей, затем Xmin, Xmax, Ymin, Ymax (в твипах)
			var nbits:int = b[0] >> 3;
			var bitPos:int = 5;
			var xMin:Number = readSigned(b, bitPos, nbits); bitPos += nbits;
			var xMax:Number = readSigned(b, bitPos, nbits); bitPos += nbits;
			var yMin:Number = readSigned(b, bitPos, nbits); bitPos += nbits;
			var yMax:Number = readSigned(b, bitPos, nbits); bitPos += nbits;
			info.width = Math.round((xMax - xMin) / 20);
			info.height = Math.round((yMax - yMin) / 20);

			b.position = Math.ceil(bitPos / 8);
			info.frameRate = b.readUnsignedShort() / 256; // формат 8.8
			info.frameCount = b.readUnsignedShort();
			var startPos:int = b.position;

			var sawFileAttributes:Boolean = false;
			var sawAbc:Boolean = false;
			var guard:int = 0;

			while (b.bytesAvailable >= 2 && guard++ < 400)
			{
				var header:uint = b.readUnsignedShort();
				var code:uint = header >> 6;
				var len:uint = header & 0x3F;
				if (len == 0x3F)
				{
					if (b.bytesAvailable < 4) break;
					len = b.readUnsignedInt();
				}
				var next:uint = b.position + len;

				if (code == 69 && len >= 1) // FileAttributes
				{
					sawFileAttributes = true;
					var flags:uint = b.readUnsignedByte();
					info.isAS3 = (flags & 0x08) != 0;
				}
				else if (code == 9 && len >= 3) // SetBackgroundColor
				{
					var r:uint = b.readUnsignedByte();
					var g:uint = b.readUnsignedByte();
					var bl:uint = b.readUnsignedByte();
					info.bgColor = (r << 16) | (g << 8) | bl;
				}
				else if (code == 72 || code == 82) // DoABC
				{
					sawAbc = true;
				}
				else if (code == 0 || code == 1) // End / ShowFrame
				{
					break;
				}

				if (next > b.length) break;
				b.position = next;
				if (sawFileAttributes && info.bgColor >= 0) break;
			}

			if (!sawFileAttributes) info.isAS3 = sawAbc;
			else if (sawAbc) info.isAS3 = true;
			info.hasVideo = videoFrames(b, startPos);
		}

		/** the main timeline has embedded video (a VideoFrame tag) — walks the top-level tags */
		private static function videoFrames(b:ByteArray, p:int):Boolean
		{
			var guard:int = 0;
			while (p + 2 <= b.length && guard++ < 300000)
			{
				b.position = p;
				var header:uint = b.readUnsignedShort();
				var code:uint = header >> 6;
				var len:uint = header & 0x3F;
				if (len == 0x3F)
				{
					if (b.bytesAvailable < 4) break;
					len = b.readUnsignedInt();
				}
				if (code == 61) return true;
				if (code == 0) break;
				p = b.position + len;
			}
			return false;
		}

		/**
		 * Does the code use the keyboard? Looks for names that only appear when a SWF reads keys:
		 * AS3 KeyboardEvent / "keyDown", AS2 Key.isDown / Key.getCode / onKeyDown.
		 */
		private static const KEY_WORDS:Array = ["KeyboardEvent", "keyDown", "keyUp", "isDown", "getCode", "onKeyDown", "onKeyUp", "keyCode"];

		/**
		 * Bytes -> searchable text. readMultiByte stops at the first zero byte on some runtimes
		 * (Android), and SWF bodies are full of zeros — so zeros become spaces first.
		 */
		private static function asText(b:ByteArray, n:uint):String
		{
			var parts:Array = [];
			var chunk:ByteArray = new ByteArray();
			for (var pos:uint = 0; pos < n; pos += 65536)
			{
				var len:uint = Math.min(65536, n - pos);
				chunk.length = 0;
				chunk.writeBytes(b, pos, len);
				for (var i:uint = 0; i < len; i++)
				{
					if (chunk[i] == 0) chunk[i] = 32;
				}
				chunk.position = 0;
				parts.push(chunk.readMultiByte(len, "iso-8859-1"));
			}
			b.position = 0;
			return parts.join("");
		}

		private static function scanKeys(b:ByteArray, info:SwfInfo):Boolean
		{
			try
			{
				var text:String = asText(b, Math.min(b.length, 64 * 1024 * 1024));
				// packed game: its code is encrypted, we can't see what it uses — keep the gamepad
				info.packed = text.indexOf("mochicrypt") >= 0;
				if (info.packed) return true;
				for each (var w:String in KEY_WORDS)
				{
					if (text.indexOf(w) >= 0) return true;
				}
				return false;
			}
			catch (e:Error)
			{
			}
			return true; // unknown — keep the gamepad
		}

		private static function readSigned(b:ByteArray, start:int, n:int):Number
		{
			if (n == 0) return 0;
			var v:Number = 0;
			for (var i:int = 0; i < n; i++)
			{
				var p:int = start + i;
				var bit:int = (b[p >> 3] >> (7 - (p & 7))) & 1;
				v = v * 2 + bit;
			}
			if (v >= Math.pow(2, n - 1)) v -= Math.pow(2, n);
			return v;
		}
	}
}
