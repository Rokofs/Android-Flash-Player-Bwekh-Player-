package fp.avm1
{
	import flash.display.DisplayObject;

	/** AS1/AS2 view of a display object (movie clip, button or text field). */
	public class AClip extends AObject
	{
		public var d:DisplayObject;
		/** library symbol id: 0 = main timeline, -1 = created by code / unknown */
		public var spriteId:int = -1;
		public var isButton:Boolean = false;
		public var isText:Boolean = false;
		/** onClipEvent handlers: [{flags, key, code}] */
		public var events:Array;
		/** text field bound to a variable: {v, html} */
		public var textVar:Object;
		public var lastText:String;
		/** depth for clips created by code (attachMovie & co.), NaN for timeline ones */
		public var dynDepth:Number = NaN;
		public var lastRunFrame:int = -1;
		public var lastRunTick:int = -1;
		/** frame already run when the clip was set up: AIR calls its frame script once more after */
		public var initFrame:int = -1;
		public var initTick:int = -1;
		/** timeline children whose first frame script waits for this clip's frame script (Flash order) */
		public var deferredKids:Array;
		/** this clip's first frame script waits for that parent's frame script */
		public var deferredBy:AClip;
		/** tick of the last goto made by code on this clip */
		public var gotoTick:int = -1;
		/** onClipEvent(load) waits for the running code to end */
		public var loadQueued:Boolean = false;
		/** stopped by a mouse / key handler on this frame (see VmDisplay.stop) */
		public var stopFrame:int = -1;
		public var stopTick:int = -100;
		public var lastSoundFrame:int = -1;
		/** lives inside a button state (up/over/down): shown and hidden by the button */
		public var inButton:Boolean = false;
		public var lastSoundTick:int = -100;
		public var alive:Boolean = true;
		public var loaded:Boolean = false;
		public var pressed:Boolean = false;
		/** a goto AIR postponed (called from a frame script): frame and the tick it was asked on */
		public var pendingGoto:* = null;
		public var pendingTick:int = -1;
		/** a loop VmDisplay plays itself: the frame it is on (0 = AIR's playhead), the loop's last frame */
		public var driveFrame:int = 0;
		/** unloadMovie() made it empty */
		public var unloaded:Boolean = false;
		/** _name set by code when AIR wouldn't rename it */
		public var altName:String = null;
		/** tick its load ran (its enterFrame starts on the next frame) */
		public var loadTick:int = -10;
		public var driveTop:int = 0;
		public var drivePlaying:Boolean = false;

		public function AClip(proto:AObject, d:DisplayObject)
		{
			super(proto);
			this.d = d;
			kind = "movieclip";
		}
	}
}
