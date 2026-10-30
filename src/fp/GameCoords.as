package fp
{
	import flash.display.DisplayObject;
	import flash.geom.Point;
	import flash.utils.ByteArray;
	import flash.utils.Endian;

	/**
	 * "Global" coordinates the way the game expects them. In Flash Player the stage scales the
	 * whole movie, so the stage's coordinates are the game's own. Here the game is scaled and
	 * moved inside the player, so localToGlobal / globalToLocal / hitTestPoint would answer in the
	 * player's coordinates: a head that follows the mouse around a point given in stage
	 * coordinates comes off its body, a hit test misses.
	 *
	 * The game's calls are renamed (same length, so only its string pool changes) to methods put
	 * on DisplayObject.prototype that convert through the game's root (the Loader it's in).
	 */
	public class GameCoords
	{
		/** the game's coordinate space: the Loader holding it (null: the real stage) */
		public static var root:DisplayObject;

		/** stage.nativeWindow for this game (see FakeWindow) */
		public static function set window(w:Object):void
		{
			install();
			DisplayObject.prototype.bwekhWindow_ = w;
		}

		private static const NAMES:Array = [
			["globalToLocal", "bwekhG2Lcoord"],
			["localToGlobal", "bwekhL2Gcoord"],
			["hitTestPoint", "bwekhHitTest"],
			// stage.nativeWindow: a desktop game's window is a FakeWindow (closing it closed the app)
			["nativeWindow", "bwekhWindow_"],
			// stage.stageWidth / stageHeight: the game's own size, as a Flash Player stage scaled to
			// the window reports it (the real stage is the whole phone screen)
			["stageWidth", "bwekhStgW_"],
			["stageHeight", "bwekhStgH__"],
			// NetStream.appendBytes: looping video made of appended bytes (see bwekh/Protos.as)
			["appendBytes", "bwekhAppend"],
			["appendBytesAction", "bwekhAppendAction"],
			// (a file played in place of appended video: shown in the game's Video, paused with its stream)
			["attachNetStream", "bwekhAttachNS__"],
			["togglePause", "bwekhToggle"]
		];

		private static var installed:Boolean = false;

		public static function install():void
		{
			if (installed) return;
			installed = true;
			var proto:Object = DisplayObject.prototype;
			proto.bwekhG2Lcoord = function(p:Point):Point {
				var r:DisplayObject = GameCoords.root;
				if (r && p && r.stage) p = r.localToGlobal(p);
				return this.globalToLocal(p);
			};
			proto.bwekhL2Gcoord = function(p:Point):Point {
				var q:Point = this.localToGlobal(p);
				var r:DisplayObject = GameCoords.root;
				return r && q && r.stage ? r.globalToLocal(q) : q;
			};
			proto.bwekhHitTest = function(x:Number, y:Number, shapeFlag:Boolean = false):Boolean {
				var r:DisplayObject = GameCoords.root;
				if (r && r.stage)
				{
					var g:Point = r.localToGlobal(new Point(x, y));
					x = g.x; y = g.y;
				}
				return this.hitTestPoint(x, y, shapeFlag);
			};
			for each (var n:Array in NAMES) proto.setPropertyIsEnumerable(n[1], false);
		}

		/** the game plays video with NetStream (AIR shows it on a surface of its own: see PlayerScreen) */
		public static var usesNetStream:Boolean = false;

		/** stage.stageWidth / stageHeight the game gets */
		public static function setStageSize(w:Number, h:Number):void
		{
			install();
			DisplayObject.prototype.bwekhStgW_ = w;
			DisplayObject.prototype.bwekhStgH__ = h;
		}

		/** the SWF with its calls renamed, or null when it makes none of them */
		public static function patch(swf:ByteArray):ByteArray
		{
			usesNetStream = false;
			var body:ByteArray = SwfBytes.decompress(swf);
			if (!body) return null;
			var version:int = swf[3];
			var n:int = patchBody(body);
			if (!n) return null;
			return wrap(body, version);
		}

		private static function wrap(body:ByteArray, version:int):ByteArray
		{
			var res:ByteArray = new ByteArray();
			res.endian = Endian.LITTLE_ENDIAN;
			res.writeUTFBytes("FWS");
			res.writeByte(version);
			res.writeUnsignedInt(body.length + 8);
			res.writeBytes(body);
			res.position = 0;
			return res;
		}

		/** renamed strings in this SWF body (and in SWFs packed in it); body is changed in place */
		private static function patchBody(body:ByteArray):int
		{
			body.endian = Endian.LITTLE_ENDIAN;
			var nbits:int = body[0] >> 3;
			var p:int = int((5 + 4 * nbits + 7) / 8) + 4;
			var total:int = 0;
			var own:int = 0; // renamed in this SWF's own code (not in SWFs packed in it)
			var out:ByteArray = null; // rebuilt only when a packed SWF changed size
			var outFrom:int = 0;
			while (p + 2 <= body.length)
			{
				body.position = p;
				var h:int = body.readUnsignedShort();
				var code:int = h >> 6;
				var len:int = h & 63;
				if (len == 63) len = body.readUnsignedInt();
				var start:int = body.position;
				if (start + len > body.length) len = body.length - start;
				if (code == 82 || code == 72)
				{
					var abcStart:int = start;
					if (code == 82)
					{
						abcStart = start + 4;
						while (abcStart < start + len && body[abcStart] != 0) abcStart++;
						abcStart++;
					}
					var k:int = 0;
					try { k = patchAbc(body, abcStart, start + len); } catch (e:Error) {}
					total += k;
					own += k;
				}
				else if (code == 87 && len > 14)
				{
					// DefineBinaryData: the real game packed in a preloader (Flash CS5 RSL preloader)
					var s0:int = body[start + 6], s1:int = body[start + 7], s2:int = body[start + 8];
					if ((s0 == 0x46 || s0 == 0x43 || s0 == 0x5A) && s1 == 0x57 && s2 == 0x53)
					{
						var inner:ByteArray = new ByteArray();
						inner.writeBytes(body, start + 6, len - 6);
						var ib:ByteArray = null;
						try { ib = SwfBytes.decompress(inner); } catch (de:Error) { ib = null; }
						var c:int = ib ? patchBody(ib) : 0;
						if (c)
						{
							total += c;
							if (!out) { out = new ByteArray(); out.endian = Endian.LITTLE_ENDIAN; }
							out.writeBytes(body, outFrom, p - outFrom);
							var nd:ByteArray = new ByteArray();
							nd.endian = Endian.LITTLE_ENDIAN;
							nd.writeBytes(body, start, 6);
							nd.writeBytes(wrap(ib, inner[3]));
							out.writeShort((87 << 6) | 63);
							out.writeUnsignedInt(nd.length);
							out.writeBytes(nd);
							outFrom = start + len;
						}
					}
				}
				p = start + len;
				if (code == 0) break;
			}
			if (out)
			{
				out.writeBytes(body, outFrom, body.length - outFrom);
				body.length = 0;
				body.writeBytes(out);
			}
			if (own) injectProtos(body);
			return total;
		}

		/**
		 * The methods the renamed calls go to (tools/so-shim/bwekh/Protos.as), compiled: put in
		 * front of the game's first code and run right away, they set the game's own prototypes.
		 */
		private static const PROTOS:String = "EAAuAAAAAwAAAAAAAOA/mpmZmZmZyT/gAQdCb29sZWFuAApEaWN0aW9uYXJ5C2ZsYXNoLnV0aWxzBVRpbWVyBUFycmF5Bk9iamVjdAVyZWFkeQxid2VraDpQcm90b3MXX19nb190b19kZWZpbml0aW9uX2hlbHADcG9zBDExMDAFc3BhY2UEMTE1MgdzdHJlYW1zBDEzNzMFd2F0Y2gEMTQzNwhtZXNzYWdlcwQxNTU2BnJlcG9ydAQxNjAzBXN0YXRlBDE3MTQFZmlsZXMEMzczNAVwYXRocwQzNzc0B2ZpbGVGb3IEMzgxOQhhcHBlbmRlZAQ0ODE5BWNoZWNrBDUzNTQIcGxheUZpbGUENjgxMQhzdGFydEFsdAQ3OTI0BWxhdGVyBDgzOTgFc2V0VXAEODU5MgZQcm90b3MFYndla2gEMTA2OS4vaG9tZS9jbGF1ZGUvZnBhL3Rvb2xzL3NvLXNoaW07Yndla2g7UHJvdG9zLmFzAWQBeARuYW1lD2J3ZWtoR2FtZUxvYWRlcgZwYXJlbnQNRGlzcGxheU9iamVjdA1mbGFzaC5kaXNwbGF5BUVycm9yAWUEdGV4dAZsZW5ndGgEcHVzaAZTdHJpbmcEdm9pZAJzdAZsb29wT2YURmlsZVByaXZhdGVOUzpQcm90b3MhaHR0cDovL2Fkb2JlLmNvbS9BUzMvMjAwNi9idWlsdGluBnBhdXNlZBVQcm90b3MuYXMkMTphbm9ueW1vdXMXUHJvdG9zLmFzJDA6YW5vbnltb3VzJDAEaW5mbwRjb2RlA2ludAVjb2RlcwZ2aWRlbyAEIGF0IAZOdW1iZXICbnMEdGltZQd0b0ZpeGVkCyBzLCBidWZmZXIgDGJ1ZmZlckxlbmd0aAN1cmwWTmV0U3RyZWFtLlBhdXNlLk5vdGlmeRhOZXRTdHJlYW0uVW5wYXVzZS5Ob3RpZnkBcANhbHQFY2xvc2UVTmV0U3RyZWFtLlBsYXkuRmFpbGVkB3JldHJpZXMTTmV0U3RyZWFtLlBsYXkuU3RvcARzZWVrBnJlc3VtZQJjZQJzZQ5OZXRTdGF0dXNFdmVudAxmbGFzaC5ldmVudHMVUHJvdG9zLmFzJDA6YW5vbnltb3VzB3N0YXRlJDACYXQBbgRsYXN0BXN0aWxsCGdldFRpbWVyCW5ldFN0YXR1cxBhZGRFdmVudExpc3RlbmVyBXRpbWVyBXN0YXJ0AWIDc3VtAWkDa2V5AUYCRlMDZGlyAWYCZnMBXwh0b1N0cmluZxNnZXREZWZpbml0aW9uQnlOYW1lFWZsYXNoLmZpbGVzeXN0ZW0uRmlsZRtmbGFzaC5maWxlc3lzdGVtLkZpbGVTdHJlYW0FQ2xhc3MbYXBwbGljYXRpb25TdG9yYWdlRGlyZWN0b3J5C2J3ZWtoLXZpZGVvC3Jlc29sdmVQYXRoD2NyZWF0ZURpcmVjdG9yeQQuZmx2BmV4aXN0cwRzaXplBXdyaXRlBG9wZW4Kd3JpdGVCeXRlcwpuYXRpdmVQYXRoDHZpZGVvIGZpbGU6IAdtZXNzYWdlCUJ5dGVBcnJheQVieXRlcxZ2aWRlbyBieXRlcyBhcHBlbmRlZCAoAiwgByBieXRlcykDbm93AWsBdANidWYCY2wFbG9vcHMWdmlkZW8gZmlsZSBzdG9wcGVkIGF0IBIgczogZnJvbSB0aGUgc3RhcnQGY2xpZW50Cm9uTWV0YURhdGERdmlkZW8gc3RvcHBlZCBhdCALIHMgKGJ1ZmZlciAgKTogdGhlIGdhbWUncyBvbk1ldGFEYXRhIGFnYWluICgBKQxvbk1ldGFEYXRhOiACbWUCdGUKVGltZXJFdmVudAFtFVByb3Rvcy5hcyQyOmFub255bW91cxVQcm90b3MuYXMkMzphbm9ueW1vdXMVUHJvdG9zLmFzJDQ6YW5vbnltb3VzB3N0YXJ0ZWQVUHJvdG9zLmFzJDU6YW5vbnltb3VzCnBsYXlGaWxlJDAXZmxhc2gubmV0Lk5ldENvbm5lY3Rpb24TZmxhc2gubmV0Lk5ldFN0cmVhbQJOQwJuYwdjb25uZWN0Ak5TDG9uUGxheVN0YXR1cwlvblhNUERhdGEDYXN0BmFsdFVybAV2aWRlbw9hdHRhY2hOZXRTdHJlYW0HdmlkZW86ICAgYnl0ZXMgb2YgRkxWIHBsYXllZCBmcm9tIGEgZmlsZRogKGl0cyBWaWRlbyBub3Qga25vd24geWV0KRF2aWRlbyBmaWxlIHBsYXk6IARwbGF5AnBlAiAoCiksIGJ5IHBhdGgZdmlkZW8gZmlsZSBwbGF5IGJ5IHBhdGg6IANwZTIVUHJvdG9zLmFzJDY6YW5vbnltb3VzAm1zB2xhdGVyJDAI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";

		private static function injectProtos(body:ByteArray):void
		{
			var nbits:int = body[0] >> 3;
			var p:int = int((5 + 4 * nbits + 7) / 8) + 4;
			while (p + 2 <= body.length)
			{
				body.position = p;
				var h:int = body.readUnsignedShort();
				var code:int = h >> 6;
				var len:int = h & 63;
				if (len == 63) len = body.readUnsignedInt();
				if (code == 82 || code == 72)
				{
					var abc:ByteArray = b64(PROTOS);
					var tag:ByteArray = new ByteArray();
					tag.endian = Endian.LITTLE_ENDIAN;
					tag.writeShort((82 << 6) | 63);
					tag.writeUnsignedInt(4 + 13 + abc.length);
					tag.writeUnsignedInt(0); // not lazy: runs when the tag is reached
					tag.writeUTFBytes("bwekh/Protos");
					tag.writeByte(0);
					tag.writeBytes(abc);
					var rest:ByteArray = new ByteArray();
					rest.writeBytes(body, p, body.length - p);
					body.length = p;
					body.position = p;
					body.writeBytes(tag);
					body.writeBytes(rest);
					return;
				}
				p = body.position + len;
				if (code == 0) return;
			}
		}

		private static function b64(s:String):ByteArray
		{
			var tbl:String = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
			var out:ByteArray = new ByteArray();
			var buf:int = 0, bits:int = 0;
			for (var i:int = 0; i < s.length; i++)
			{
				var v:int = tbl.indexOf(s.charAt(i));
				if (v < 0) continue;
				buf = ((buf << 6) | v) & 0xFFFFFF;
				bits += 6;
				if (bits >= 8)
				{
					bits -= 8;
					out.writeByte((buf >> bits) & 0xFF);
				}
			}
			out.position = 0;
			return out;
		}

		private static function u30(b:ByteArray):uint
		{
			var r:uint = 0;
			for (var i:int = 0; i < 5; i++)
			{
				var c:uint = b.readUnsignedByte();
				r |= (c & 0x7F) << (7 * i);
				if (!(c & 0x80)) break;
			}
			return r;
		}

		/** rename the strings in one ABC's string pool (in place); how many */
		/**
		 * Rename the strings in one ABC's string pool (in place); how many. A name the ABC itself
		 * defines (a trait: an interface method like mx.core.IFlexDisplayObject.globalToLocal, an
		 * override) is left alone — renamed, its class would no longer match (VerifyError).
		 */
		private static function patchAbc(b:ByteArray, from:int, end:int):int
		{
			b.position = from + 4;
			var n:int, i:int, j:int, c:int;
			n = u30(b); for (i = 1; i < n; i++) u30(b);       // ints
			n = u30(b); for (i = 1; i < n; i++) u30(b);       // uints
			n = u30(b); if (n > 1) b.position += 8 * (n - 1); // doubles
			n = u30(b);
			// the strings to rename: index -> [offset, new name]
			var found:Object = {};
			var any:Boolean = false;
			for (i = 1; i < n && b.position < end; i++)
			{
				var l:int = u30(b);
				var at:int = b.position;
				if (l == 9 && b.readUTFBytes(9) == "NetStream") usesNetStream = true;
				b.position = at;
				if (l >= 10 && l <= 17)
				{
					var str:String = b.readUTFBytes(l);
					for each (var pair:Array in NAMES)
					{
						if (str == pair[0]) { found[i] = [at, pair[1]]; any = true; }
					}
				}
				b.position = at + l;
			}
			if (!any) return 0;
			// namespaces, namespace sets
			n = u30(b); for (i = 1; i < n; i++) { b.readUnsignedByte(); u30(b); }
			n = u30(b); for (i = 1; i < n; i++) { c = u30(b); for (j = 0; j < c; j++) u30(b); }
			// multinames: their name string
			n = u30(b);
			var mnName:Array = [0];
			for (i = 1; i < n; i++)
			{
				var k:int = b.readUnsignedByte();
				var nm:int = 0;
				switch (k)
				{
					case 0x07: case 0x0D: u30(b); nm = u30(b); break;
					case 0x0F: case 0x10: nm = u30(b); break;
					case 0x11: case 0x12: break;
					case 0x09: case 0x0E: nm = u30(b); u30(b); break;
					case 0x1B: case 0x1C: u30(b); break;
					case 0x1D: u30(b); c = u30(b); for (j = 0; j < c; j++) u30(b); break;
					default: return 0; // unknown: don't touch it
				}
				mnName.push(nm);
			}
			// methods, metadata
			n = u30(b);
			for (i = 0; i < n; i++)
			{
				var pc:int = u30(b);
				u30(b);
				for (j = 0; j < pc; j++) u30(b);
				u30(b);
				var fl:int = b.readUnsignedByte();
				if (fl & 0x08) { c = u30(b); for (j = 0; j < c; j++) { u30(b); b.readUnsignedByte(); } }
				if (fl & 0x80) for (j = 0; j < pc; j++) u30(b);
			}
			n = u30(b);
			for (i = 0; i < n; i++) { u30(b); c = u30(b); for (j = 0; j < 2 * c; j++) u30(b); }
			// trait names: those strings are the ABC's own definitions
			var defined:Object = {};
			var cc:int = u30(b);
			for (i = 0; i < cc; i++)
			{
				u30(b); u30(b);
				var f:int = b.readUnsignedByte();
				if (f & 0x08) u30(b);
				c = u30(b); for (j = 0; j < c; j++) u30(b);
				u30(b);
				traitNames(b, mnName, defined);
			}
			for (i = 0; i < cc; i++) { u30(b); traitNames(b, mnName, defined); }
			n = u30(b);
			for (i = 0; i < n; i++) { u30(b); traitNames(b, mnName, defined); }
			var count:int = 0;
			for (var si:String in found)
			{
				if (defined[si]) continue;
				b.position = found[si][0];
				b.writeUTFBytes(found[si][1]);
				count++;
			}
			return count;
		}

		private static function traitNames(b:ByteArray, mnName:Array, out:Object):void
		{
			var c:int = u30(b);
			for (var i:int = 0; i < c; i++)
			{
				var nm:int = u30(b);
				if (nm < mnName.length) out[mnName[nm]] = true;
				var k:int = b.readUnsignedByte();
				var kind:int = k & 0x0F;
				if (kind == 0 || kind == 6)
				{
					u30(b); u30(b);
					if (u30(b)) b.readUnsignedByte();
				}
				else
				{
					u30(b); u30(b);
				}
				if (k & 0x40) { var m:int = u30(b); for (var j:int = 0; j < m; j++) u30(b); }
			}
		}
	}
}
