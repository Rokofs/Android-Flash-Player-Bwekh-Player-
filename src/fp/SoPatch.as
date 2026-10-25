package fp
{
	import flash.utils.ByteArray;
	import flash.utils.Endian;

	/**
	 * Save games for AS3 files played in AIR: the game's references to flash.net.SharedObject and
	 * flash.external.ExternalInterface are pointed at bwekh.SharedObject / bwekh.ExternalInterface
	 * (source: tools/so-shim), whose code is added to the SWF here. They keep each game's saves
	 * (and browser-cookie saves) in its own folder, and the player writes them out on close.
	 */
	public class SoPatch
	{
		public static const CLASS_NAME:String = "bwekh.SharedObject";

		/** returns the patched SWF (uncompressed), or null when the game doesn't use SharedObject */
		public static function patch(swf:ByteArray):ByteArray
		{
			var body:ByteArray = SwfBytes.decompress(swf);
			if (!body) return null;
			swf.position = 0;
			var version:int = swf[3];
			// RECT + frame rate + frame count
			var nbits:int = body[0] >> 3;
			var p:int = int((5 + 4 * nbits + 7) / 8) + 4;
			var out:ByteArray = new ByteArray();
			out.endian = Endian.LITTLE_ENDIAN;
			out.writeBytes(body, 0, p);
			var changed:Boolean = false;
			var shimAdded:Boolean = false;
			body.endian = Endian.LITTLE_ENDIAN;
			while (p + 2 <= body.length)
			{
				body.position = p;
				var h:int = body.readUnsignedShort();
				var code:int = h >> 6;
				var len:int = h & 63;
				if (len == 63) len = body.readUnsignedInt();
				var start:int = body.position;
				if (start + len > body.length) len = body.length - start;
				var done:Boolean = false;
				if (code == 82 || code == 72)
				{
					var abcStart:int = start;
					var head:ByteArray = new ByteArray();
					if (code == 82)
					{
						abcStart = start + 4;
						while (abcStart < start + len && body[abcStart] != 0) abcStart++;
						abcStart++;
						head.writeBytes(body, start, abcStart - start);
					}
					var abc:ByteArray = new ByteArray();
					abc.writeBytes(body, abcStart, start + len - abcStart);
					var patched:ByteArray = null;
					try { patched = patchAbc(abc); } catch (e:Error) { patched = null; }
					if (!shimAdded)
					{
						for each (var shim:ByteArray in shimAbcs())
						{
							var sh:ByteArray = new ByteArray();
							sh.endian = Endian.LITTLE_ENDIAN;
							sh.writeUnsignedInt(1);
							sh.writeUTFBytes("bwekh");
							sh.writeByte(0);
							sh.writeBytes(shim);
							writeTag(out, 82, sh);
						}
						shimAdded = true;
					}
					if (patched)
					{
						changed = true;
						var nb:ByteArray = new ByteArray();
						nb.writeBytes(head);
						nb.writeBytes(patched);
						writeTag(out, code, nb);
						done = true;
					}
				}
				if (!done) out.writeBytes(body, p, start + len - p);
				p = start + len;
				if (code == 0) break;
			}
			if (!changed) return null;
			var res:ByteArray = new ByteArray();
			res.endian = Endian.LITTLE_ENDIAN;
			res.writeUTFBytes("FWS");
			res.writeByte(version);
			res.writeUnsignedInt(out.length + 8);
			res.writeBytes(out);
			res.position = 0;
			return res;
		}

		private static function writeTag(out:ByteArray, code:int, data:ByteArray):void
		{
			out.writeShort((code << 6) | 63);
			out.writeUnsignedInt(data.length);
			out.writeBytes(data);
		}

		// ------------------------------------------------------------------ ABC

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

		private static function w30(b:ByteArray, v:uint):void
		{
			do
			{
				var c:uint = v & 0x7F;
				v >>>= 7;
				if (v) c |= 0x80;
				b.writeByte(c);
			}
			while (v);
		}

		/** classes replaced: package, name */
		private static const TARGETS:Array = [["flash.net", "SharedObject"], ["flash.external", "ExternalInterface"]];

		/** the ABC with the TARGETS classes turned into bwekh ones, or null if it uses none */
		public static function patchAbc(abc:ByteArray):ByteArray
		{
			abc.endian = Endian.LITTLE_ENDIAN;
			abc.position = 4;
			var i:int, j:int, t:int, n:int;
			var T:int = TARGETS.length;
			n = u30(abc); for (i = 1; i < n; i++) u30(abc);   // int
			n = u30(abc); for (i = 1; i < n; i++) u30(abc);   // uint
			n = u30(abc); if (n > 1) abc.position += 8 * (n - 1);   // double
			var strStart:int = abc.position;
			var strCount:int = u30(abc);
			var strBodyStart:int = abc.position;
			// per target: string indexes of its name and of its package
			var nameStr:Array = [], pkgStr:Array = [], pkgNs:Array = [], pkgSet:Array = [];
			for (t = 0; t < T; t++) { nameStr.push({}); pkgStr.push({}); pkgNs.push({}); pkgSet.push({}); }
			var bwekhStr:int = -1;
			var anyName:Boolean = false;
			for (i = 1; i < strCount; i++)
			{
				var sl:int = u30(abc);
				if (sl >= 5 && sl <= 17)
				{
					var s:String = abc.readUTFBytes(sl);
					if (s == "bwekh") bwekhStr = i;
					for (t = 0; t < T; t++)
					{
						if (s == TARGETS[t][1]) { nameStr[t][i] = true; anyName = true; }
						else if (s == TARGETS[t][0]) pkgStr[t][i] = true;
					}
				}
				else abc.position += sl;
			}
			if (!anyName) return null;
			var strBodyEnd:int = abc.position;
			// namespaces
			var nsCount:int = u30(abc);
			var nsKind:Array = [0], nsName:Array = [0];
			for (i = 1; i < nsCount; i++)
			{
				var k:int = abc.readUnsignedByte();
				var nm:int = u30(abc);
				nsKind.push(k); nsName.push(nm);
				if (k == 0x16) for (t = 0; t < T; t++) if (pkgStr[t][nm]) pkgNs[t][i] = true;
			}
			// namespace sets
			var setCount:int = u30(abc);
			var sets:Array = [null];
			for (i = 1; i < setCount; i++)
			{
				var c:int = u30(abc);
				var arr:Array = [];
				for (j = 0; j < c; j++)
				{
					var ns:int = u30(abc);
					arr.push(ns);
					for (t = 0; t < T; t++) if (pkgNs[t][ns]) pkgSet[t][i] = true;
				}
				sets.push(arr);
			}
			// multinames
			var mnCount:int = u30(abc);
			var mns:Array = [null];
			var hits:int = 0;
			for (i = 1; i < mnCount; i++)
			{
				var m:Object = { k: abc.readUnsignedByte() };
				switch (m.k)
				{
					case 0x07: case 0x0D: m.ns = u30(abc); m.name = u30(abc);
						for (t = 0; t < T; t++) if (pkgNs[t][m.ns] && nameStr[t][m.name]) { m.fix = true; hits++; }
						break;
					case 0x0F: case 0x10: m.name = u30(abc); break;
					case 0x11: case 0x12: break;
					case 0x09: case 0x0E: m.name = u30(abc); m.set = u30(abc);
						for (t = 0; t < T; t++) if (pkgSet[t][m.set] && nameStr[t][m.name]) { m.fix = true; hits++; }
						break;
					case 0x1B: case 0x1C: m.set = u30(abc); break;
					case 0x1D: m.qn = u30(abc); var pc:int = u30(abc); m.params = [];
						for (j = 0; j < pc; j++) m.params.push(u30(abc));
						break;
					default: return null;   // unknown: leave this ABC alone
				}
				mns.push(m);
			}
			if (!hits) return null;
			var restStart:int = abc.position;

			var out:ByteArray = new ByteArray();
			out.endian = Endian.LITTLE_ENDIAN;
			out.writeBytes(abc, 0, strStart);
			// strings (+ "bwekh")
			var addStr:Boolean = bwekhStr < 0;
			if (addStr) bwekhStr = Math.max(1, strCount);
			w30(out, addStr ? Math.max(1, strCount) + 1 : strCount);
			if (strBodyEnd > strBodyStart) out.writeBytes(abc, strBodyStart, strBodyEnd - strBodyStart);
			if (addStr) { w30(out, 5); out.writeUTFBytes("bwekh"); }
			// namespaces (+ package bwekh)
			var newNs:int = Math.max(1, nsCount);
			w30(out, newNs + 1);
			for (i = 1; i < nsCount; i++) { out.writeByte(nsKind[i]); w30(out, nsName[i]); }
			out.writeByte(0x16); w30(out, bwekhStr);
			// sets
			w30(out, setCount);
			for (i = 1; i < setCount; i++)
			{
				w30(out, sets[i].length);
				for each (var sn:int in sets[i]) w30(out, sn);
			}
			// multinames
			w30(out, mnCount);
			for (i = 1; i < mnCount; i++)
			{
				m = mns[i];
				if (m.fix)
				{
					out.writeByte(m.k == 0x0D || m.k == 0x0E ? 0x0D : 0x07);
					w30(out, newNs); w30(out, m.name);
					continue;
				}
				out.writeByte(m.k);
				switch (m.k)
				{
					case 0x07: case 0x0D: w30(out, m.ns); w30(out, m.name); break;
					case 0x0F: case 0x10: w30(out, m.name); break;
					case 0x09: case 0x0E: w30(out, m.name); w30(out, m.set); break;
					case 0x1B: case 0x1C: w30(out, m.set); break;
					case 0x1D: w30(out, m.qn); w30(out, m.params.length);
						for each (var pp:int in m.params) w30(out, pp);
						break;
				}
			}
			out.writeBytes(abc, restStart, abc.length - restStart);
			return out;
		}

		// ------------------------------------------------------------------ shim code

		private static var shimBytes:Array;

		private static function shimAbcs():Array
		{
			if (!shimBytes)
			{
				shimBytes = [];
				for each (var s:String in SHIMS) shimBytes.push(b64(s));
			}
			return shimBytes;
		}

		private static function b64(s:String):ByteArray
		{
			const T:String = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
			var out:ByteArray = new ByteArray();
			var buf:uint = 0, bits:int = 0;
			for (var i:int = 0; i < s.length; i++)
			{
				var v:int = T.indexOf(s.charAt(i));
				if (v < 0) continue;
				buf = (buf << 6) | v;
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

		/** ABC of tools/so-shim/bwekh/*.as (see tools/so-shim/README.txt) */
		private static const SHIMS:Array = [
			"EAAuAAAAAFEHQm9vbGVhbgAGT2JqZWN0Em1hcnNoYWxsRXhjZXB0aW9ucxdfX2dvX3RvX2RlZmluaXRpb25faGVscANwb3MDNTEw" +
			"B2Nvb2tpZXMXYndla2g6RXh0ZXJuYWxJbnRlcmZhY2UDNTY3CWF2YWlsYWJsZQM2MTMIb2JqZWN0SUQDNzkyC2FkZENhbGxiYWNr" +
			"Azk2MwRjYWxsBDExNzUEZmlsZQQyMTM5BGxvYWQEMjI4MARzYXZlBDI2OTMRRXh0ZXJuYWxJbnRlcmZhY2UFYndla2gDNDY5OS9o" +
			"b21lL2NsYXVkZS9mcGEvdG9vbHMvc28tc2hpbTtid2VraDtFeHRlcm5hbEludGVyZmFjZS5hcxNnZXREZWZpbml0aW9uQnlOYW1l" +
			"C2ZsYXNoLnV0aWxzIGZsYXNoLmV4dGVybmFsLkV4dGVybmFsSW50ZXJmYWNlH0ZpbGVQcml2YXRlTlM6RXh0ZXJuYWxJbnRlcmZh" +
			"Y2UhaHR0cDovL2Fkb2JlLmNvbS9BUzMvMjAwNi9idWlsdGluBUVycm9yAWUGU3RyaW5nDGZ1bmN0aW9uTmFtZQdjbG9zdXJlCEZ1" +
			"bmN0aW9uBHZvaWQEYXJncwFmA2tleQF2BGRheXMEcmVhbAt0b0xvd2VyQ2FzZQZjb29raWUHaW5kZXhPZgZsZW5ndGgGUmVnRXhw" +
			"IShzZXR8d3JpdGV8c2F2ZXxjcmVhdGV8cHV0fHN0b3JlKQR0ZXN0Bk51bWJlchsoZXJhc2V8ZGVsZXRlfHJlbW92ZXxjbGVhcikP" +
			"KGdldHxyZWFkfGxvYWQpBmNvbmNhdAVhcHBseQFkDFNoYXJlZE9iamVjdAZmb2xkZXILY29va2llcy5hbWYLcmVzb2x2ZVBhdGgC" +
			"ZnMBYgFvBmV4aXN0cwpmaWxlU3RyZWFtBHJlYWQEb3BlbglCeXRlQXJyYXkJcmVhZEJ5dGVzBWNsb3NlCHBvc2l0aW9uCnJlYWRP" +
			"YmplY3QGcGFyZW50D2NyZWF0ZURpcmVjdG9yeQt3cml0ZU9iamVjdAV3cml0ZQp3cml0ZUJ5dGVzChYCBQkWGhYeGgkaAxcaBSAI" +
			"IQIIAgUGAwcIAQkvBwEBBwEDBwEEBwIIBwELBwENBwEPBwERBwITBwIVBwIXBwMZBwQdCQsBBwEiBwcjCQ0BBwEkCQ8BBwEnBwEo" +
			"BwEvBwExBwEyGwEHATMHATUHATYJEQEHATkJOgEHAzwHAT0JPwEJQwEHB0QJRgEHBEcJSAEJSQEHAUoHAUsJTAEJTQEHAU4JUAEK" +
			"AAAAAAABCwAAEg0AAhUSFA+AJSYBABIRhCUAAhMAABUVAAAVFwAAAAAAAAAAAAoFAQYHBQEGCgUBBgwFAQYOBQEGEAUBBhIFAQYU" +
			"BQEGFgUBBhgFAQYbAQwCAQAJAAgJA0AAAQoKAQAEQAACAAEBBUIAAQECBkIAAgEDB0EAAwEECEEABAEFCUEABQEGCkEABgEHC0EA" +
			"BwEIAQABDEQAAAEJCgEDBAACJtAw8RxdDfATLB9GDQFmDtbSSBAOAADQMFoAKtcqMCttAR3wFCdIAQQSFg8QAAIDBAACJtAw8Rxd" +
			"DfAZLB9GDQFmEdbSSBAOAADQMFoAKtcqMCttAR3wGiBIAQQSFg8QAAMDBQACLtAw8RzvASUAAO8BJgEAXQ3wHywfRg0B0dJPEwIQ" +
			"DQAA0DBaACpjBCowK20BHUcBDhwgDxAABAUKAAGDA9Aw8RzvASUAAO8BKQEA7wEqAgDvASsDAO8BLAQA7wEtBQDvAS4GANESCgAA" +
			"0fAkRhYAEAIAACwChdfT8CUsMEYXASQAsCoSBwAAKdNmGCQorSoSCQAAKdJmGCQBsPAlEgIBAF0K8CdPCgBgEmTS8CgkAGYZQQGF" +
			"YwRgGvApLDRCAdNGGwEqEgkAACnSZhgkArDwKRJ9AADS8CskAWYZYwXS8CxmGCQDDw4AAGAcZNIkAmYZQQEQAgAAJAF1YwZiBfAt" +
			"IKwqEQUAACliBSGsKhELAAApYBJkYgVBASwCqyoRCAAAKWIGJACt8C0SCwAAYARiBGoZKRAPAABgBGIEYBLwLmRiBUEBYRldC/Av" +
			"TwsA8DAgSGAa8DIsN0IB00YbAfAyEhQAAGAEYgTwNGoZKV0L8DVPCwDwNiBIYBrwOCw4QgHTRhsB8DgSGQAAYARiBPA6ZhkhGQoA" +
			"AGAEYgRmGRABAAAgSF0N8D0sH0YNAYACKmMH8D5mHSDRVgHSRh4BRh8CSAAABQICAAEm0DDxHO8BOwAAYCDwQ0YhAIAC1dESDAAA" +
			"0fBELD5GIgEQAQAAIEgAAAYDBwACpAHQMPEc7wEqAADvAUABAO8BQQIA7wFCAwBgBBIFAADwSUfwSlUAXgQrYQRdCfBNRgkAgALV" +
			"0fBOlioRBQAAKdFmI5YSAQAAR2Ag8E9GJACAAtbS0fBQLEVPJQJdJvBRSiYAgCbX0tPwUk8nAdLwU08oANPwVCQAYSnT8FVGKgCA" +
			"AipjBBILAABiBF4E8FYrYQTwSxANAADQMFoAKmMGKjArbQEdRwEqkgGWAQ8QAAcDBgACc9Aw8RzvASoAAO8BQQEA7wFAAgBdCfBf" +
			"RgkAgALV0fBgEQEAAEfR8GFmK08sAF0m8GJKJgCAJtbSYATwY08tAWAg8GRGJACAAtfT0fBlLE9PJQLT0vBmTy4B0/BnTygA8F0Q" +
			"DQAA0DBaACpjBSowK20BHUcBE2FlDxAACAABAAABRwAACQEBAAEG0DDQSQBHAAAAAwEAAg7QMGUAYAIqMFgAHWgMRwAA",
			"EAAuAAMDAAAAmAEEdWludAAGT2JqZWN0B0Jvb2xlYW4VZGVmYXVsdE9iamVjdEVuY29kaW5nF19fZ29fdG9fZGVmaW5pdGlvbl9o" +
			"ZWxwA3BvcwM2MzMDZGlyEmJ3ZWtoOlNoYXJlZE9iamVjdAM2ODYIZGlyVHJpZWQDNzE5A2FsbAM3NjYKc3RvcmFnZURpcgVid2Vr" +
			"aAQxMTQ3CmZpbGVTdHJlYW0EMTI4NwZmb2xkZXIEMTUxMAdzYXZlRGlyBDE1ODIEc2FmZQQyMDUzCGdldExvY2FsBDIxNjUJZ2V0" +
			"UmVtb3RlBDI2OTAJZGVsZXRlQWxsBDI5MDQMZ2V0RGlza1VzYWdlBDI5NzAIZmx1c2hBbGwEMzEyNQZOdW1iZXIGU3RyaW5nBGRh" +
			"dGEDNzk3BmNsaWVudAM4MjgOb2JqZWN0RW5jb2RpbmcDODU2A2ZwcwM4OTQEZmlsZQM5MjQDa2V5Azk1MQhyZWFkRmlsZQQzMzA3" +
			"B3JlYWRPbGQEMzgwNwl3cml0ZUZpbGUENDE4OQVmbHVzaAQ0NjI5BWNsZWFyBDQ3MjgFY2xvc2UENDg4OAdjb25uZWN0BDQ5MjME" +
			"c2VuZAQ1MDAxCHNldERpcnR5BDUwNDILc2V0UHJvcGVydHkENTA5OQRzaXplBDUyMjAMU2hhcmVkT2JqZWN0D0V2ZW50RGlzcGF0" +
			"Y2hlcgxmbGFzaC5ldmVudHMDNTczHF9fZ29fdG9fY3Rvcl9kZWZpbml0aW9uX2hlbHADOTgyNC9ob21lL2NsYXVkZS9mcGEvdG9v" +
			"bHMvc28tc2hpbTtid2VraDtTaGFyZWRPYmplY3QuYXMTZ2V0RGVmaW5pdGlvbkJ5TmFtZQtmbGFzaC51dGlscxVmbGFzaC5maWxl" +
			"c3lzdGVtLkZpbGUbYXBwbGljYXRpb25TdG9yYWdlRGlyZWN0b3J5HGZsYXNoLmV2ZW50czpFdmVudERpc3BhdGNoZXIaRmlsZVBy" +
			"aXZhdGVOUzpTaGFyZWRPYmplY3QhaHR0cDovL2Fkb2JlLmNvbS9BUzMvMjAwNi9idWlsdGluAUMbZmxhc2guZmlsZXN5c3RlbS5G" +
			"aWxlU3RyZWFtBUNsYXNzA2N1cgJmcwRuYW1lFXNhdmVzLWFzMy9jdXJyZW50LnR4dAtyZXNvbHZlUGF0aARyZWFkBG9wZW4OYnl0" +
			"ZXNBdmFpbGFibGUMcmVhZFVURkJ5dGVzBlJlZ0V4cAleXHMrfFxzKyQBZwdyZXBsYWNlCnNhdmVzLWFzMy8FRXJyb3IBZQFzEFte" +
			"QS1aYS16MC05Ll8tXSsBXwlsb2NhbFBhdGgGc2VjdXJlAWsCc28BZAF8BC5hbWYKcmVtb3RlUGF0aAtwZXJzaXN0ZW5jZQdyZW1v" +
			"dGU6A3VybANpbnQBbgFiAW8GZXhpc3RzCUJ5dGVBcnJheQlyZWFkQnl0ZXMIcG9zaXRpb24KcmVhZE9iamVjdAZvYmplY3QEcmVh" +
			"bANvbGQBcBZmbGFzaC5uZXQuU2hhcmVkT2JqZWN0BHZvaWQDdG1wC3dyaXRlT2JqZWN0BnBhcmVudA9jcmVhdGVEaXJlY3RvcnkE" +
			"LnRtcAV3cml0ZQp3cml0ZUJ5dGVzBm1vdmVUbwxtaW5EaXNrU3BhY2UHZmx1c2hlZApkZWxldGVGaWxlDG15Q29ubmVjdGlvbgZw" +
			"YXJhbXMEYXJncwxwcm9wZXJ0eU5hbWUFdmFsdWUGbGVuZ3RoDRYCBQoXERYRFksWURoKGlQaAwVVCFYYCgQJAgcICQQDCgELCgIH" +
			"CAkEAwoBCwwKAgwHCAkEAwoBC0oHAQEHAQMHAQQHAQUHAgkHAgwHAg4HAxAHAxMHARUHAhcHAhkHARsHAR0HAR8HASEHASMHASUH" +
			"ASYHAScHASkHASsHAS0HAi8HAjEHAjMHAjUHAjcHATkHATsHAT0HAT8HAUEHAUMHAUUHAUcHBEkHBUoHBlAJUwEHAVkJXgEJYAEJ" +
			"YQEJYgEJPQEHAWMHAWYHAWgHA2kbAgleAgcBeAl8AwlgAwcGfQl+Awk9AwcBfwcBgAEJGwMJJwMbAwcBhgEHAYgBCYkBAwmKAQMJ" +
			"XAMJXgMJjQEDCY4BAwmRAQMHAZcBGAAAAAAAAhAAAAITAAACFQAAAhcAARMTGYBqAyUTEwMbiAIMDAoKXG1uBCUTEwIDHYgDDAwK" +
			"CgoKXHR1bgE1Ex+AdwE1EyGAdwA1IwAAAzMAA0ATEwM1gFxtbgADNwABEzU5iAECA48BAEA7AABAPQACQAITP4gBDAySAZMBAEBB" +
			"hAFAE0OAlQECQBMCRYgBDAyVAZYBAAFHAAAAAAAAAEkAIQYBBwgGAQcLBgEHDQYBBw8GAQcSBgEHFAYBBxYGAQcYBgEHGgYBBxwG" +
			"AQceBgEHIAYBByIGAQckBgEHKAYBByoGAQcsBgEHLgYBBzAGAQcyBgEHNAYBBzYGAQc4BgEHOgYBBzwGAQc+BgEHQAYBB0IGAQdE" +
			"BgEHRgYBB0gGAQdMTQEHTgElJgEAFxEUQAACAAEOFUAAAgABDxZAAAEBAwEQF0AAEgIDAREYQAACAAESGUAAEwABExpBAAsBFBtB" +
			"AAwBFRxBAA0BFh1BAA4BFx5BAA8BGB9BABABGSBBABEBGiFBABIBGyJBABMBHCNBABQBHSRCABUBHhYOBEAAAQEDAQAFQAACAAEB" +
			"BkAAAwoKAQIHQAACAAEDCEEAAQEECUEAAgEFCkEAAwEGC0EABAEHDEEABQEIDUEABgEJDkEABwEKD0EACAELEEEACQEMEUEACgEN" +
			"AQABJUQAAAIfIBgBAgEAARDQMPFPXSfwJixSRicBZihIAAACAgIAAR7QMPFP7wFXAABdJ/ArLFhGJwFgKYeAKdXwLNFCAEgAAAMB" +
			"AQABDNAw8U9dC/AyRgsASAAABAQGAAKbAdAw8U/vAVoAAO8BWwEA7wFcAgBgBhIHAABgBfA3SPA4Jl4GK2EGXQjwO0YIACxdRioB" +
			"gALVXQnwPEYJAIAC1tLR8D0sX08rAtLS8D5mLEYtAYXX0vA/Ty4A02Av8EAsZCxlQgIsAkYwAoXX0xIVAABdCPBBRggALGfToEYq" +
			"AV4FK2EF8DkQDQAA0DBaACpjBSowK20BHWAF8ERIASaFAYkBMTIABQQCAAEl0DDxT+8BagAA0RIUAADRYC/wSSxrLGVCAixsRjAC" +
			"EAIAACwCSAAABgUJAALJAdAw8U/vAVwAAO8BbQEA7wFuAgDvAW8DAO8BcAQA7wFxBQDSKhEFAAAp8E4sAixyoNGghWMEYAdiBPBP" +
			"ZjOAJSpjBRIHAABiBfBQSPBR0EIAgCUqYwViBPBSYRlgB2IEYgXwU2EzXQvwVEYLAIACKmMG8FUSOgAAYgViBtISDwAAXQzS8FdG" +
			"DAEsbKAQAgAALAJdDNFGDAGgLHOgRjQBYRgQDQAA0DBaACpjCCowK20BHWIF8FlGGgARCAAAYgXR0tNPGwNiBfBaSAF3oAGkATEy" +
			"AAcFBQABL9Aw8U/vAVwAAO8BdAEA7wF1AgDvAW4DAF0N0fBfLHbSKhEDAAApLAKgYgRGDQNIAAAIAQIAAQ7QMPFP7wF3AADwYiQA" +
			"SAAACQECAAEO0DDxT+8BdwAA8GQkAEgAAAoCBgABVNAw8U/vAXkAAO8BbwEA7wFwAgDwaSQA1SQAYwVgB2MEECUAAAliBGIFHoXW" +
			"YAfS8GxmM4Al19MqEgcAACnT8G1GHAASAgAAwgEyBAUR1P//0fBvSAAACwMIAAKgAdAw8U/vAVsAAO8BegEA7wF7AgBgGPB0EQIA" +
			"ACdIYBjwd2Y2EQUAACcqYwVIXQnweEYJAIAC1dFgGPB5LF9PNwJdOPB6SjgAgDjW0dLwe085AdHwfE86ANLwfSQAYTvS8H5GPACA" +
			"AtfT8H8gq5YqEgcAACnTlSyBAasSDQAA014UK2EUJipjBkjwdRAQAADQMFoAKmMHKjArbQEd8IIBJ0gBHYoBjgExMgAMBAsAAqkB" +
			"0DDxT+8BXAAA7wFtAQDvAW4CAO8BggEDAO8BgwEEAO8BeQUA7wGEAQYAXSfwigEshQFGJwGAAipjBNHS0/CLAUY9A4ACKmMFKhIL" +
			"AAApYgXwjAFmPvCMARI7AADwjgEkAGMGJABjCmIF8I8BZj5jCRAZAAAJYgliCh6FYwdgFGIHYgVmPmIHZj9hP8IGMgkKEeD///CI" +
			"ARANAADQMFoAKmMKKjArbQEdRwEqlwGbATEyAA0DBwACogHQMPFP7wF6AADvAYcBAQDvAVsCAGAY8JcBEQIAACdIXTjwmgFKOACA" +
			"ONXRYBTwmwFPQQFgGPCcAWZCT0MAYBjwnQFmQmAYZkQsiwGgRkUBgALWXQnwngFGCQCAAtfT0vCfASyMAU83AtPR8KABT0YB0/Ch" +
			"AU86ANJgGPCiASZPRwLwowEmKmMFSPCYARAQAADQMFoAKmMGKjArbQEd8KYBJ0gBH4wBkAExMgAOAQIAARnQMPFP7wGPAQAAXRzw" +
			"qwFPHADwrAEskAFIAAAPAwQAAlPQMPFP7wGEAQAAJADXYBTWEA8AAAnS0x6F1WAU0fCxAWo/KTICAxHq//9gGCoSCAAAKWAY8LIB" +
			"ZjYSBQAAYBhPSAAQDAAA0DBaACrWKjArbQEdRwEqQkYxMgAQAQEAAQXQMPFPRwAAEQEDAAER0DDxT+8BkgEAAO8BkwEBAEcAABIB" +
			"AwABC9Aw8U/vAZQBAABHAAATAQIAAQvQMPFP7wGVAQAARwAAFAMDAAEa0DDxT+8BlQEAAO8BlgEBAGAU0dLwvwFhP0cAABUDBQAC" +
			"QNAw8U/vAXoAAF048MYBSjgAgDjV0WAU8McBT0EB0fDIAWZJ19NI8MQBEBAAANAwWgAqYwQqMCttAR3wywEkAEgBCSktMTIAFwIB" +
			"AAEd0DDxT/FP8BZVAF4UK2EU8B/QSQDQXhXwICthFUcAABYCAQABDtAw8U/wFFUAXgcrYQdHAAAAAwEAAxLQMGUAYAIwYCYqMFgA" +
			"HR1oJUcAAA=="
		];
	}
}
