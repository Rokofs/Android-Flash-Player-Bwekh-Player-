package fp.ui
{
	import flash.display.Shape;
	import flash.display.Sprite;
	import flash.events.Event;
	import flash.text.TextField;
	import flash.utils.Dictionary;

	import fp.Library;
	import fp.LibraryItem;

	/** "File list" tab. */
	public class FileListScreen extends Sprite
	{
		private var _lib:Library;
		private var _scroll:ScrollView;
		private var _cards:Array = [];
		private var _empty:Sprite;
		private var _emptyTitle:TextField;
		private var _emptyText:TextField;
		private var _w:Number = 100;
		private var _h:Number = 100;

		public var onPlay:Function;
		public var onShare:Function;
		public var onMenu:Function;

		public function FileListScreen(lib:Library)
		{
			_lib = lib;
			_scroll = new ScrollView();
			addChild(_scroll);

			_empty = new Sprite();
			_empty.mouseEnabled = false;
			_empty.mouseChildren = false;
			var ic:Shape = Icons.shape("swf", M.px(72), M.ACCENT, 0.35);
			ic.name = "icon";
			_empty.addChild(ic);
			_emptyTitle = M.text("No SWF files yet", 18, M.TEXT, true);
			_empty.addChild(_emptyTitle);
			_emptyText = M.text("Tap + to pick a file with any file manager.\nIt will be copied into the SWF folder.", 14, M.TEXT2, false, M.px(300), true);
			M.center(_emptyText);
			_empty.addChild(_emptyText);
			addChild(_empty);

			_scroll.addEventListener(Event.SCROLL, updateVisible);
			_lib.addEventListener(Event.CHANGE, onListChanged);
			_lib.addEventListener(Library.ITEM_UPDATED, onItemUpdated);
		}

		public function layout(w:Number, h:Number):void
		{
			_w = w;
			_h = h;
			_scroll.setSize(w, h);
			graphics.clear();
			graphics.beginFill(M.BG);
			graphics.drawRect(0, 0, w, h);
			graphics.endFill();
			positionCards();

			var ic:Shape = Shape(_empty.getChildByName("icon"));
			ic.x = (w - ic.width) / 2;
			ic.y = 0;
			_emptyTitle.x = (w - _emptyTitle.width) / 2;
			_emptyTitle.y = ic.height + M.px(16);
			_emptyText.x = (w - _emptyText.width) / 2;
			_emptyText.y = _emptyTitle.y + _emptyTitle.height + M.px(8);
			_empty.y = Math.round((h - _empty.height) / 2.4);
		}

		private function onListChanged(e:Event):void
		{
			rebuild();
		}

		/** cards of the items, kept between rebuilds (a new list only adds and removes cards) */
		private var _byItem:Dictionary = new Dictionary();

		public function rebuild():void
		{
			var y:Number = _scroll.content.y;
			_scroll.content.removeChildren();
			var old:Dictionary = _byItem;
			_byItem = new Dictionary();
			_cards = [];
			for each (var it:LibraryItem in _lib.items)
			{
				var card:FileCard = old[it] as FileCard;
				if (card) delete old[it];
				else
				{
					card = new FileCard(it, cardWidth, _scroll, play, share, menu);
					refreshCard(card);
				}
				_byItem[it] = card;
				_scroll.content.addChild(card);
				_cards.push(card);
			}
			for each (var gone:FileCard in old) gone.dispose();
			_empty.visible = _cards.length == 0;
			positionCards();
			_scroll.scrollTo(-y);
			updateVisible();
		}

		/** only the cards on screen are drawn (the rest are skipped by the renderer) */
		private function updateVisible(e:Event = null):void
		{
			var top:Number = -_scroll.content.y - M.px(120);
			var bottom:Number = -_scroll.content.y + _scroll.viewHeight + M.px(120);
			for each (var c:FileCard in _cards)
				c.visible = c.y + c.cardHeight >= top && c.y <= bottom;
		}

		private function get cardWidth():Number
		{
			return Math.min(_w - M.px(32), M.px(720));
		}

		private function positionCards():void
		{
			var cw:Number = cardWidth;
			var y:Number = M.px(12);
			for each (var c:FileCard in _cards)
			{
				c.setWidth(cw);
				c.x = Math.round((_w - cw) / 2);
				c.y = y;
				y += c.cardHeight + M.px(12);
			}
			// extra space at the end so the last card isn't glued to the bottom bar
			_scroll.contentHeight = y;
			_scroll.bottomPadding = M.px(32);
			_scroll.scrollTo(-_scroll.content.y);
			updateVisible();
		}

		private function onItemUpdated(e:Event):void
		{
			var it:LibraryItem = _lib.updatedItem;
			for each (var c:FileCard in _cards)
			{
				if (c.item == it) refreshCard(c);
			}
		}

		/** texts of all cards (after a setting that changes them) */
		public function refreshCards():void
		{
			for each (var c:FileCard in _cards) refreshCard(c);
		}

		private function refreshCard(c:FileCard):void
		{
			c.refresh(_lib.hasThumb(c.item) ? _lib.thumbFile(c.item) : null);
		}

		private function play(it:LibraryItem):void { if (onPlay != null) onPlay(it); }
		private function share(it:LibraryItem):void { if (onShare != null) onShare(it); }
		private function menu(it:LibraryItem):void { if (onMenu != null) onMenu(it); }
	}
}
