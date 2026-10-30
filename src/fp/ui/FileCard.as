package fp.ui
{
	import flash.display.Bitmap;
	import flash.display.Graphics;
	import flash.display.BitmapData;
	import flash.geom.Matrix;
	import flash.display.Loader;
	import flash.display.Shape;
	import flash.display.Sprite;
	import flash.events.Event;
	import flash.events.IOErrorEvent;
	import flash.events.MouseEvent;
	import flash.events.TimerEvent;
	import flash.filesystem.File;
	import flash.filesystem.FileMode;
	import flash.filesystem.FileStream;
	import flash.text.TextField;
	import flash.utils.ByteArray;
	import flash.utils.Timer;

	import fp.LibraryItem;
	import fp.Log;

	/** One SWF in the list: thumbnail, name, duration, play and share buttons. Long press = menu. */
	public class FileCard extends Sprite
	{
		public var item:LibraryItem;
		/** (file name):String — engine label for ActionScript 1/2 files, set by Main */
		public static var legacyEngine:Function;

		private var _w:Number;
		private var _h:Number;
		private var _thumbBox:Sprite;
		/** thumbnails made small once, by file and its date (a rebuilt list doesn't read them again) */
		private static var _thumbCache:Object = {};
		private var _thumbKey:String;
		private var _name:TextField;
		private var _ext:TextField;
		private var _tag:TextField;
		private var _dur:TextField;
		private var _play:IconButton;
		private var _share:IconButton;
		private var _press:Shape;
		private var _longTimer:Timer;
		private var _longFired:Boolean = false;
		private var _thumbLoader:Loader;

		private var _onPlay:Function;
		private var _onShare:Function;
		private var _onMenu:Function;
		private var _scroll:ScrollView;

		public function FileCard(item:LibraryItem, width:Number, scroll:ScrollView,
		                         onPlay:Function, onShare:Function, onMenu:Function)
		{
			this.item = item;
			_scroll = scroll;
			_onPlay = onPlay;
			_onShare = onShare;
			_onMenu = onMenu;
			_h = M.px(112);

			_press = new Shape();
			addChild(_press);

			_thumbBox = new Sprite();
			_thumbBox.mouseEnabled = false;
			_thumbBox.mouseChildren = false;
			addChild(_thumbBox);

			_name = M.text("", 16, M.TEXT, true);
			_ext = M.text(item.extension, 13, M.TEXT3);
			_tag = M.text("", 12, M.TEXT3);
			_dur = M.text("", 14, M.TEXT2);
			addChild(_name);
			addChild(_ext);
			addChild(_tag);
			addChild(_dur);

			_play = new IconButton("playCircle", M.ACCENT, 48, 32, M.ACCENT);
			_play.addEventListener(MouseEvent.CLICK, function(e:MouseEvent):void {
				e.stopPropagation();
				_onPlay(item);
			});
			addChild(_play);

			_share = new IconButton("share", M.TEXT2, 48, 24);
			_share.addEventListener(MouseEvent.CLICK, function(e:MouseEvent):void {
				e.stopPropagation();
				_onShare(item);
			});
			addChild(_share);

			_longTimer = new Timer(550, 1);
			_longTimer.addEventListener(TimerEvent.TIMER_COMPLETE, onLong);
			addEventListener(MouseEvent.MOUSE_DOWN, onDown);
			addEventListener(MouseEvent.MOUSE_UP, onUp);
			addEventListener(MouseEvent.ROLL_OUT, onUp);
			addEventListener(MouseEvent.CLICK, onClick);

			setWidth(width);
			refresh();
		}

		public function get cardHeight():Number { return _h; }

		public function setWidth(w:Number):void
		{
			if (w == _w) return;
			_w = w;
			graphics.clear();
			graphics.beginFill(M.SURFACE);
			graphics.drawRoundRect(0, 0, _w, _h, M.px(8), M.px(8));
			graphics.endFill();
			M.elevate(this, 2);
			// a card changes rarely: drawn once into a bitmap (with its shadow), not every frame
			cacheAsBitmap = true;

			var pad:Number = M.px(16);
			_thumbBox.x = pad;
			_thumbBox.y = pad;

			_play.x = _w - _play.size - M.px(4);
			_play.y = M.px(4);
			_share.x = _w - _share.size - M.px(4);
			_share.y = _h - _share.size - M.px(4);
			layoutText();
		}

		/** the thumbnail square: dark, rounded, with the picture (bd) filling it */
		private function drawThumbBox(bd:BitmapData):void
		{
			while (_thumbBox.numChildren) _thumbBox.removeChildAt(0);
			var tb:Number = M.px(80);
			var r:Number = M.px(8);
			var g:Graphics = _thumbBox.graphics;
			g.clear();
			g.beginFill(0x111111);
			g.drawRoundRect(0, 0, tb, tb, r, r);
			g.endFill();
			if (bd)
			{
				var m:Matrix = new Matrix();
				m.translate((tb - bd.width) / 2, (tb - bd.height) / 2);
				g.beginBitmapFill(bd, m, false, false);
				g.drawRoundRect((tb - bd.width) / 2, (tb - bd.height) / 2, bd.width, bd.height, r, r);
				g.endFill();
			}
		}

		/** the list is gone: nothing more to load */
		public function dispose():void
		{
			_thumbLoader = null;
			_longTimer.stop();
		}

		private function layoutText():void
		{
			var tx:Number = M.px(112);
			var maxW:Number = _w - tx - M.px(56) - _ext.width - M.px(4);
			M.fit(_name, item.baseName, Math.max(M.px(40), maxW));
			_name.x = tx;
			_name.y = M.px(16);
			_ext.x = _name.x + _name.width + M.px(4);
			_ext.y = _name.y + _name.height - _ext.height - M.px(1);
			_tag.x = tx;
			_tag.y = _name.y + _name.height + M.px(2);
			_dur.x = tx;
			_dur.y = _h - _dur.height - M.px(16);
		}

		/** Update texts and thumbnail from the item. */
		public function refresh(thumb:File = null):void
		{
			var info:Object = item.info;
			if (!info)
			{
				_tag.text = "reading…";
				_dur.text = "duration: --:--:--";
			}
			else if (!info.ok)
			{
				_tag.text = "not a SWF file";
				_dur.text = "duration: --:--:--";
			}
			else
			{
				var eng:String = legacyEngine != null ? legacyEngine(item.name, info.as3 === true, info.video === true) : "";
				_tag.text = (info.as3 ? "ActionScript 3" + (eng == "Ruffle" ? " · Ruffle" : "") : "ActionScript 1/2 · " + eng) +
					(info.w > 0 ? "  ·  " + info.w + "×" + info.h : "");
				_dur.text = "duration: " + M.formatTime(item.duration);
			}
			layoutText();
			if (thumb) loadThumb(thumb);
			else drawPlaceholder();
		}

		private function drawPlaceholder():void
		{
			drawThumbBox(null);
			var s:Number = M.px(40);
			var ic:Shape = Icons.shape("swf", s, M.ACCENT);
			ic.x = ic.y = (M.px(80) - s) / 2;
			_thumbBox.addChild(ic);
		}

		private function loadThumb(f:File):void
		{
			try
			{
				var key:String = f.nativePath + "|" + f.modificationDate.time;
				var cached:BitmapData = _thumbCache[key] as BitmapData;
				if (cached)
				{
					_thumbKey = key;
					_thumbLoader = null;
					drawThumbBox(cached);
					return;
				}
				if (key == _thumbKey && _thumbLoader) return; // already loading it
				_thumbKey = key;
				var bytes:ByteArray = new ByteArray();
				var fs:FileStream = new FileStream();
				fs.open(f, FileMode.READ);
				fs.readBytes(bytes);
				fs.close();
				// several refreshes can overlap (list rebuilt + header read): only the newest load counts
				var ld:Loader = new Loader();
				_thumbLoader = ld;
				ld.contentLoaderInfo.addEventListener(Event.COMPLETE, function(e:Event):void {
					if (ld == _thumbLoader) onThumb(key);
				});
				ld.contentLoaderInfo.addEventListener(IOErrorEvent.IO_ERROR, function(e:IOErrorEvent):void {
					Log.write("card: thumbnail of " + item.name + " can't be read: " + e.text);
					if (ld == _thumbLoader) drawPlaceholder();
				});
				ld.loadBytes(bytes);
			}
			catch (e:Error)
			{
				Log.error("card.thumb " + item.name, e);
				drawPlaceholder();
			}
		}

		private function onThumb(key:String):void
		{
			var bmp:Bitmap = _thumbLoader ? _thumbLoader.content as Bitmap : null;
			_thumbLoader = null;
			if (!bmp || !bmp.bitmapData)
			{
				drawPlaceholder();
				return;
			}
			// scaled down once, smoothly, to the size it shows at
			var src:BitmapData = bmp.bitmapData;
			var box:Number = M.px(80);
			var sc:Number = Math.min(box / src.width, box / src.height, 1);
			var w:int = Math.max(1, Math.round(src.width * sc)), h:int = Math.max(1, Math.round(src.height * sc));
			var small:BitmapData = new BitmapData(w, h, false, 0x111111);
			var m:Matrix = new Matrix();
			m.scale(w / src.width, h / src.height);
			small.draw(src, m, null, null, null, true);
			src.dispose();
			_thumbCache[key] = small;
			drawThumbBox(small);
		}

		// ------------------------------------------------------------ touch

		private function onDown(e:MouseEvent):void
		{
			_longFired = false;
			_longTimer.reset();
			_longTimer.start();
			_press.graphics.clear();
			_press.graphics.beginFill(0x000000, 0.05);
			_press.graphics.drawRoundRect(0, 0, _w, _h, M.px(8), M.px(8));
			_press.graphics.endFill();
		}

		private function onUp(e:MouseEvent):void
		{
			_longTimer.reset();
			_press.graphics.clear();
		}

		private function onLong(e:TimerEvent):void
		{
			_press.graphics.clear();
			if (_scroll && _scroll.dragged) return;
			_longFired = true;
			_onMenu(item);
		}

		private function onClick(e:MouseEvent):void
		{
			if (_longFired)
			{
				_longFired = false;
				return;
			}
			_onPlay(item);
		}
	}
}
