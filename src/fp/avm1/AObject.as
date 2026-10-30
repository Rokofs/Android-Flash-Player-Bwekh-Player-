package fp.avm1
{
	/**
	 * An ActionScript 1/2 object: own properties + prototype (__proto__).
	 * Property keys are normalized by the VM (lower case for SWF 6 and older, which are
	 * case-insensitive). Internally they are stored with a "$" prefix, so names like
	 * "hasOwnProperty" or "constructor" don't clash with the AS3 Object they live in.
	 */
	public class AObject
	{

		private var store:Object = {};

		/** "$" + k, made once per name (no new string on every look-up) */
		private static var prefixed:Object = {};

		public static function pk(k:String):String
		{
			var p:String = prefixed[k] as String;
			if (p == null) { p = "$" + k; try { prefixed[k] = p; } catch (e:Error) {} }
			return p;
		}
		private var acc:Object;
		public var proto:AObject;
		/** shown by typeof / toString */
		public var kind:String = "object";
		/** property keys in creation order, for for..in */
		public var order:Array = [];

		public function AObject(proto:AObject = null)
		{
			this.proto = proto;
		}

		/** own plain property (not addProperty) */
		public function hasValue(k:String):Boolean
		{
			return (AObject.pk(k) in store);
		}

		public function hasOwn(k:String):Boolean
		{
			var p:String = AObject.pk(k);
			return (p in store) || (acc != null && (p in acc));
		}

		/** marks "no such own value" (lookup) */
		public static const ABSENT:Object = {};

		/** own plain value, or ABSENT: one look instead of hasValue + getOwn */
		public function lookup(k:String):*
		{
			var pk:String = AObject.pk(k);
			var v:* = store[pk];
			if (v === undefined && !(pk in store)) return ABSENT;
			return v;
		}

		public function get hasAccessors():Boolean
		{
			return acc != null;
		}

		public function getOwn(k:String):*
		{
			var pk:String = AObject.pk(k);
			return (pk in store) ? store[pk] : undefined;
		}

		public function setOwn(k:String, v:*):void
		{
			var pk:String = AObject.pk(k);
			if (!(pk in store)) order.push(k);
			store[pk] = v;
		}

		public function deleteOwn(k:String):Boolean
		{
			var pk:String = AObject.pk(k);
			if (!(pk in store)) return false;
			delete store[pk];
			var i:int = order.indexOf(k);
			if (i >= 0) order.splice(i, 1);
			return true;
		}

		/** addProperty getter/setter: {get, set} or null */
		public function getAccessor(k:String):Object
		{
			if (!acc) return null;
			var pk:String = AObject.pk(k);
			return (pk in acc) ? acc[pk] : null;
		}

		public function setAccessor(k:String, getter:*, setter:*):void
		{
			if (!acc) acc = {};
			acc[AObject.pk(k)] = { "get": getter, "set": setter };
		}

		/** Object that holds k: this or a prototype; null if none. */
		public function findHolder(k:String):AObject
		{
			var o:AObject = this;
			var guard:int = 0;
			while (o && guard++ < 100)
			{
				if (o.hasOwn(k)) return o;
				o = o.proto;
			}
			return null;
		}
	}
}
