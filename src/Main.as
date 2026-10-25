package
{
	import flash.desktop.NativeApplication;
	import flash.desktop.SystemIdleMode;
	import flash.display.Sprite;
	import flash.display.StageAlign;
	import flash.display.StageAspectRatio;
	import flash.display.StageDisplayState;
	import flash.display.StageQuality;
	import flash.display.StageScaleMode;
	import flash.events.Event;
	import flash.utils.getTimer;
	import flash.utils.ByteArray;
	import flash.filesystem.FileMode;
	import flash.filesystem.FileStream;
	import flash.events.InvokeEvent;
	import flash.events.KeyboardEvent;
	import flash.events.StatusEvent;
	import flash.events.UncaughtErrorEvent;
	import flash.events.ErrorEvent;
	import flash.filesystem.File;
	import flash.net.FileFilter;
	import flash.system.Capabilities;
	import flash.ui.Keyboard;
	import flash.ui.Multitouch;
	import flash.ui.MultitouchInputMode;

	import fp.Keys;
	import fp.Library;
	import fp.Log;
	import fp.LibraryItem;
	import fp.NativeBridge;
	import fp.PlayerScreen;
	import fp.Settings;
	import fp.SwfConvert;
	import fp.ui.AboutScreen;
	import fp.ui.AppBar;
	import fp.ui.BottomNav;
	import fp.ui.DialogLayer;
	import fp.ui.FileCard;
	import fp.ui.FileListScreen;
	import fp.ui.GamepadLayoutScreen;
	import fp.ui.M;
	import fp.ui.SettingsScreen;
	import fp.ui.Snackbar;

	/**
	 * Bwekh Player for Android (Adobe AIR / HARMAN AIR SDK).
	 * Portrait library UI (Material Design) + landscape player with on-screen gamepad.
	 */
	[SWF(frameRate="60", backgroundColor="#F5F5F5")]
	public class Main extends Sprite
	{
		private var settings:Settings;
		private var nativeExt:NativeBridge;
		private var lib:Library;

		private var ui:Sprite;
		private var appBar:AppBar;
		private var nav:BottomNav;
		private var listScreen:FileListScreen;
		private var settingsScreen:SettingsScreen;
		private var layoutScreen:GamepadLayoutScreen;
		private var aboutScreen:AboutScreen;
		private var dialogs:DialogLayer;
		private var snack:Snackbar;

		private var tab:int = 0;
		/** system bars over the app, refreshed by checkInsets() */
		private var insets:Object = { l: 0, t: 0, r: 0, b: 0 };
		private var insetTick:int = 0;
		private var inLayoutScreen:Boolean = false;
		private var player:PlayerScreen;

		public function Main()
		{
			if (stage) init();
			else addEventListener(Event.ADDED_TO_STAGE, init);
		}

		private function init(e:Event = null):void
		{
			removeEventListener(Event.ADDED_TO_STAGE, init);
			stage.scaleMode = StageScaleMode.NO_SCALE;
			stage.align = StageAlign.TOP_LEFT;
			stage.quality = StageQuality.HIGH;
			stage.stageFocusRect = false;
			Multitouch.inputMode = MultitouchInputMode.TOUCH_POINT;
			M.init();

			settings = new Settings();
			settings.load();
			nativeExt = new NativeBridge();
			Log.init(nativeExt.externalFilesDir());
			Log.write("native extension: " + nativeExt.available + ", screen " + stage.stageWidth + "x" + stage.stageHeight + ", dpi " + Capabilities.screenDPI);
			nativeExt.addEventListener(StatusEvent.STATUS, onNativeStatus);

			lib = new Library();
			lib.setDir(resolveListDir());
			updateExtraDirs();

			ui = new Sprite();
			addChild(ui);

			listScreen = new FileListScreen(lib);
			listScreen.onPlay = function(it:LibraryItem):void { play(it); };
			listScreen.onShare = share;
			listScreen.onMenu = itemMenu;
			FileCard.legacyEngine = function(name:String, as3:Boolean = false):String {
				var en:String = settings.engineFor(name, as3);
				return Settings.engineName(en);
			};
			ui.addChild(listScreen);

			settingsScreen = new SettingsScreen(settings);
			settingsScreen.currentPath = function():String { return lib.dir ? lib.dir.nativePath : ""; };
			settingsScreen.onPickFolder = pickFolder;
			settingsScreen.onLayout = function():void { showLayoutScreen(true); };
			settingsScreen.onQuality = pickQuality;
			settingsScreen.onResolution = pickResolution;
			settingsScreen.onEngine = pickDefaultEngine;
			settingsScreen.onChanged = function():void { settings.save(); };
			settingsScreen.onDownloads = function():void {
				settings.save();
				updateExtraDirs();
				lib.scan();
				if (settings.indexDownloads) askFileAccess(true);
			};
			ui.addChild(settingsScreen);

			dialogs = new DialogLayer();
			layoutScreen = new GamepadLayoutScreen(settings, dialogs);
			layoutScreen.onChanged = function():void { settings.save(); };
			ui.addChild(layoutScreen);

			aboutScreen = new AboutScreen();
			ui.addChild(aboutScreen);

			appBar = new AppBar();
			appBar.addEventListener(AppBar.ACTION, function(ev:Event):void { addFile(); });
			appBar.addEventListener(AppBar.BACK, function(ev:Event):void { showLayoutScreen(false); });
			ui.addChild(appBar);

			nav = new BottomNav();
			nav.addEventListener(Event.CHANGE, function(ev:Event):void { showTab(nav.selected); });
			ui.addChild(nav);

			addChild(dialogs);
			snack = new Snackbar();
			addChild(snack);

			stage.addEventListener(Event.RESIZE, function(ev:Event):void { layout(); });
			stage.addEventListener(KeyboardEvent.KEY_DOWN, onKey, true, 1000);
			// on some phones (Android 6) the back key doesn't always reach the stage, and AIR then
			// does its default action (leave the app): listen on the application too, and swallow
			// the key-up as well
			NativeApplication.nativeApplication.addEventListener(KeyboardEvent.KEY_DOWN, onKey, false, 1000);
			NativeApplication.nativeApplication.addEventListener(KeyboardEvent.KEY_UP, onKeyUp, false, 1000);
			stage.addEventListener(KeyboardEvent.KEY_UP, onKeyUp, true, 1000);
			// show any unexpected error on screen instead of failing silently
			loaderInfo.uncaughtErrorEvents.addEventListener(UncaughtErrorEvent.UNCAUGHT_ERROR, onUncaught);
			NativeApplication.nativeApplication.addEventListener(Event.ACTIVATE, onActivate);
			NativeApplication.nativeApplication.addEventListener(InvokeEvent.INVOKE, onInvoke);
			NativeApplication.nativeApplication.addEventListener(Event.DEACTIVATE, onDeactivate);

			addEventListener(Event.ENTER_FRAME, checkInsets);
			insets = nativeExt.insets();
			setPortrait();
			showTab(0);
			lib.scan();
			layout();
			askFileAccess(false);
		}

		// ================================================================= Download folder

		private function get downloadsDir():File
		{
			try
			{
				var d:File = new File("/storage/emulated/0/Download");
				if (d.exists) return d;
				return new File("/sdcard/Download");
			}
			catch (e:Error)
			{
			}
			return null;
		}

		private function updateExtraDirs():void
		{
			var d:File = settings.indexDownloads ? downloadsDir : null;
			lib.extraDirs = d ? [d] : [];
		}

		/**
		 * Android 11+ hides other apps' non-media files (.swf) in Download unless the app has
		 * "Access all files"; older versions need the storage permission. Ask once on start
		 * (always when the user turns the option on).
		 */
		private function askFileAccess(force:Boolean):void
		{
			if (!settings.indexDownloads || !nativeExt.available || nativeExt.hasAllFilesAccess()) return;
			if (settings.askedAccess && !force) return;
			settings.askedAccess = true;
			settings.save();
			dialogs.showConfirm("Show games from Downloads",
				"Bwekh Player can list the .swf files you put in the Download folder. " +
				"Android needs the \"Access all files\" permission for that: turn it on on the next screen, then come back.",
				"Allow", function(yes:Boolean):void {
					if (yes) nativeExt.requestAllFilesAccess();
					else snack.show("Files from Downloads won't be listed. You can allow it later in Settings.");
				});
		}

		// ================================================================= folders

		private function get defaultListDir():File
		{
			var ext:String = nativeExt.externalFilesDir();
			if (ext)
			{
				try { return new File(ext).resolvePath("swf"); } catch (e:Error) {}
			}
			return File.applicationStorageDirectory.resolvePath("swf");
		}

		private function resolveListDir():File
		{
			if (settings.listPath)
			{
				try { return new File(settings.listPath); } catch (e:Error) {}
			}
			return defaultListDir;
		}

		private function pickFolder():void
		{
			var options:Array = [
				"Default — " + defaultListDir.nativePath,
				"/sdcard/swf",
				"/sdcard/Download",
				"Custom path…"
			];
			var cur:int = settings.listPath == "" ? 0
				: settings.listPath == "/sdcard/swf" ? 1
				: settings.listPath == "/sdcard/Download" ? 2 : 3;
			dialogs.showOptions("SWF list path", options, cur, function(i:int):void {
				if (i == 0) setListPath("");
				else if (i == 1) setListPath("/sdcard/swf");
				else if (i == 2) setListPath("/sdcard/Download");
				else
				{
					dialogs.showInput("Custom path", settings.listPath || "/sdcard/", "Full path to a folder with .swf files", function(t:String):void {
						if (t != null && t.replace(/\s/g, "").length > 0) setListPath(t.replace(/^\s+|\s+$/g, ""));
					});
				}
			});
		}

		private function setListPath(path:String):void
		{
			settings.listPath = path;
			settings.save();
			lib.setDir(resolveListDir());
			updateExtraDirs();
			var ok:Boolean = lib.scan();
			settingsScreen.refresh();
			if (path != "" && nativeExt.available && !nativeExt.hasAllFilesAccess())
			{
				dialogs.showConfirm("Allow file access",
					"To use a folder outside the app, Android needs the \"Access all files\" permission for Bwekh Player. " +
					"Turn it on on the next screen, then come back.",
					"Open settings", function(yes:Boolean):void {
						if (yes) nativeExt.requestAllFilesAccess();
					});
			}
			else if (!ok)
			{
				snack.show("Can't open " + lib.dir.nativePath);
			}
		}

		private function pickResolution():void
		{
			var values:Array = Settings.RENDER_RES;
			var names:Array = [];
			for each (var r:int in values) names.push(SettingsScreen.resolutionName(r));
			var cur:int = values.indexOf(settings.renderRes);
			dialogs.showOptions("Render resolution", names, cur < 0 ? 0 : cur, function(i:int):void {
				settings.renderRes = values[i];
				settings.save();
				settingsScreen.refresh();
			});
		}

		private function pickDefaultEngine(as3:Boolean):void
		{
			var list:Array = Settings.enginesFor(as3);
			var names:Array = [];
			for each (var en:String in list) names.push(Settings.engineInfo(en, as3));
			var cur:int = list.indexOf(as3 ? settings.as3Engine : settings.legacyEngine);
			dialogs.showOptions(as3 ? "Engine for ActionScript 3" : "Engine for ActionScript 1/2", names, cur < 0 ? 0 : cur, function(i:int):void {
				if (as3) settings.as3Engine = list[i];
				else settings.legacyEngine = list[i];
				settings.save();
				settingsScreen.refresh();
				listScreen.refreshCards();
			});
		}

		private function pickQuality():void
		{
			var values:Array = ["low", "medium", "high", "best"];
			var names:Array = [];
			for each (var v:String in values) names.push(SettingsScreen.qualityName(v));
			dialogs.showOptions("Render quality", names, values.indexOf(settings.quality), function(i:int):void {
				settings.quality = values[i];
				settings.save();
				settingsScreen.refresh();
			});
		}

		// ================================================================= files

		private function addFile():void
		{
			if (nativeExt.available)
			{
				if (!nativeExt.pickFile(lib.dir.nativePath)) snack.show("Couldn't open the file picker");
				return;
			}
			// fallback without the native extension (desktop testing)
			var f:File = File.documentsDirectory;
			f.addEventListener(Event.SELECT, function(ev:Event):void {
				var src:File = File(ev.target);
				try
				{
					src.copyTo(lib.dir.resolvePath(src.name), true);
					lib.scan();
					snack.show("Added " + src.name);
				}
				catch (err:Error)
				{
					snack.show("Can't copy: " + err.message);
				}
			});
			try
			{
				f.browseForOpen("Choose a SWF", [new FileFilter("Flash (*.swf)", "*.swf"), new FileFilter("All files", "*.*")]);
			}
			catch (err:Error)
			{
				snack.show("File picker isn't available here");
			}
		}

		private function onNativeStatus(e:StatusEvent):void
		{
			switch (e.code)
			{
				case "pick":
					lib.scan();
					var fname:String = e.level.substr(e.level.lastIndexOf("/") + 1);
					if (fname.toLowerCase().substr(-4) != ".swf")
						snack.show("Added " + fname + " — it doesn't look like a .swf file");
					else
						snack.show("Added " + fname);
					break;
				case "opened":
					checkOpened();
					break;
				case "ruffle_closed":
					onRuffleClosed();
					break;
				case "ruffle_pad":
					if (ruffleItem)
					{
						settings.padFiles[ruffleItem.name] = e.level == "1";
						settings.save();
					}
					break;
				case "ruffle_perf":
					Log.write("ruffle perf: " + e.level);
					break;
				case "ruffle_error":
					// the page shows the reason and offers the built-in engine ("ruffle_fallback")
					Log.write("Ruffle error: " + e.level);
					break;
				case "ruffle_navigated":
					Log.write("Ruffle: the game opened " + e.level + ", started it over");
					break;
				case "ruffle_crashed":
					// Ruffle's process died (WebView: most often not enough memory for this game)
					Log.write("Ruffle crashed: " + e.level);
					snack.show(e.level == "memory" ? "Ruffle ran out of memory. Try the AVM1 engine (long press on the file)"
						: "Ruffle crashed. Try the AVM1 engine (long press on the file)");
					break;
				case "ruffle_unsupported":
					// the WebView is too old for Ruffle: use the built-in engines from now on
					Log.write("Ruffle unsupported: " + e.level);
					if (settings.legacyEngine == Settings.ENGINE_RUFFLE) settings.legacyEngine = Settings.ENGINE_AVM1;
					if (settings.as3Engine == Settings.ENGINE_RUFFLE) settings.as3Engine = Settings.ENGINE_AIR;
					settings.save();
					ruffleUnsupported = true;
					ruffleUnsupportedWhy = e.level;
					// play this game with the built-in engine right away
					if (ruffleItem) ruffleFallback = ruffleItem;
					break;
				case "ruffle_fallback":
					ruffleFallback = ruffleItem;
					if (!ruffleOn)
					{
						// "closed" came first (or the app was activated already): act now
						ruffleOn = true;
						onRuffleClosed();
					}
					break;
				case "pick_error":
					snack.show("Couldn't add the file: " + e.level);
					break;
				case "share_error":
					snack.show("Couldn't share: " + e.level);
					break;
			}
		}

		private function share(it:LibraryItem):void
		{
			if (!nativeExt.available)
			{
				snack.show("Sharing works on Android only");
				return;
			}
			if (!nativeExt.share(it.file.nativePath, "application/x-shockwave-flash", it.name))
				snack.show("Couldn't share " + it.name);
		}

		private function itemMenu(it:LibraryItem):void
		{
			var options:Array = ["Play"];
			var engineOption:String = null;
			if (it.info && it.info.ok)
			{
				engineOption = "Engine: " + Settings.engineName(settings.engineFor(it.name, it.info.as3 === true)) + "…";
				options.push(engineOption);
			}
			options.push("Share", "Delete");
			dialogs.showOptions(it.name, options, -1, function(i:int):void {
				var choice:String = options[i];
				if (choice == "Play") play(it);
				else if (choice == engineOption) pickEngine(it);
				else if (choice == "Share") share(it);
				else if (choice == "Delete")
				{
					dialogs.showConfirm("Delete file?", it.name + " will be removed from the device.", "Delete", function(yes:Boolean):void {
						if (yes && !lib.remove(it)) snack.show("Couldn't delete " + it.name);
					});
				}
			});
		}

		/** engine for one ActionScript 1/2 file */
		private function pickEngine(it:LibraryItem):void
		{
			var as3:Boolean = it.info && it.info.as3 === true;
			var list:Array = Settings.enginesFor(as3);
			var names:Array = [];
			for each (var en:String in list) names.push(Settings.engineInfo(en, as3));
			var cur:int = list.indexOf(settings.engineFor(it.name, as3));
			dialogs.showOptions("Engine for " + it.name, names, cur, function(i:int):void {
				if (i < 0 || i >= list.length) return;
				var now:String = list[i];
				settings.engineFiles[it.name] = now;
				settings.save();
				listScreen.refreshCards();
				snack.show(it.name + ": " + Settings.engineInfo(now, as3));
			});
		}

		// ================================================================= playing

		private function play(it:LibraryItem):void
		{
			if (player) return;
			var info:Object = lib.readInfo(it);
			if (!info.ok)
			{
				snack.show(it.name + " isn't a SWF file");
				return;
			}
			Log.write("play: " + it.name);
			if (settings.engineFor(it.name, info.as3 === true) == Settings.ENGINE_RUFFLE &&
				nativeExt && nativeExt.available)
			{
				playRuffle(it, info);
				return;
			}
			dialogs.close();
			ui.visible = false;
			snack.visible = false;
			setLandscape();
			try
			{
				player = new PlayerScreen(it, settings, lib, function(msg:String):void { snack.show(msg, 5000); });
				player.insetsFn = getInsets;
				player.addEventListener(Event.CLOSE, onPlayerClosed);
				addChildAt(player, getChildIndex(dialogs));
			}
			catch (err:Error)
			{
				reportError("Player failed to start", err);
				if (player && player.parent) removeChild(player);
				player = null;
				ui.visible = true;
				setPortrait();
				layout();
			}
		}

		// ================================================================= Ruffle

		/** a game is open in Ruffle (RuffleActivity on top of the app) */
		private var ruffleOn:Boolean = false;
		private var ruffleAt:int = -100000;
		private var ruffleItem:LibraryItem;
		/** "Play with AVM1/AIR" was pressed on Ruffle's error screen */
		private var ruffleFallback:LibraryItem;
		private var ruffleUnsupported:Boolean = false;
		private var ruffleUnsupportedWhy:String = "";

		private function playRuffle(it:LibraryItem, info:Object):void
		{
			// a double tap must not open two players
			if (ruffleOn && getTimer() - ruffleAt < 3000) return;
			dialogs.close();
			var cfg:Object = {
				swf: "/game/" + encodeURIComponent(it.file.name),
				name: it.name,
				quality: settings.quality,
				renderRes: settings.renderRes,
				fallback: info.as3 === true ? "AIR" : "AVM1",
				pad: padConfig(settings.padFor(it.name, info.keys), padLayoutOf(it))
			};
			ruffleItem = it;
			ruffleOn = true;
			ruffleAt = getTimer();
			Log.write("play with Ruffle: " + it.name);
			if (!nativeExt.playRuffle(it.file.nativePath, JSON.stringify(cfg)))
			{
				ruffleOn = false;
				snack.show("Couldn't start Ruffle");
			}
		}

		/** gamepad keys for an AS1/AS2 game in Ruffle: picked from the keys its code reads */
		private function padLayoutOf(it:LibraryItem):Object
		{
			var info:Object = it.info || {};
			if (info.as3 !== false || !settings.padAuto) return null;
			try
			{
				var b:ByteArray = new ByteArray();
				var fs:FileStream = new FileStream();
				fs.open(it.file, FileMode.READ);
				fs.readBytes(b);
				fs.close();
				var conv:SwfConvert = SwfConvert.convert(b, true);
				var lay:Object = settings.padLayout(conv ? conv.keys : null);
				Log.write("ruffle: keys in the code " + (conv ? conv.keys.join(",") : "?") + " -> pad " + lay.dpad.join(",") + " / " + lay.buttons.join(","));
				return lay;
			}
			catch (e:Error)
			{
				Log.write("ruffle: key scan failed: " + e.message);
			}
			return null;
		}

		/** the on-screen gamepad settings for the Ruffle page */
		private function padConfig(show:Boolean, lay:Object = null):Object
		{
			if (!lay) lay = settings.padLayout(null);
			var key:Function = function(code:int):Object {
				var k:Object = Keys.byCode(code);
				if (!k) return null;
				return { key: k.key, code: k.jsCode, kc: code, label: k.label, loc: k.loc };
			};
			var dpad:Array = [];
			for each (var c:int in lay.dpad) dpad.push(key(c));
			var btns:Array = [];
			for (var i:int = 0; i < 4; i++) btns.push(lay.buttons[i] ? key(lay.buttons[i]) : null);
			return {
				show: show,
				available: settings.gamepadEnabled,
				opacity: settings.gamepadOpacity,
				scale: settings.gamepadScale,
				swap: settings.gamepadSwap,
				dpad: dpad,
				buttons: btns
			};
		}

		private function onRuffleClosed():void
		{
			if (!ruffleOn) return;
			ruffleOn = false;
			Log.write("Ruffle closed");
			if (ruffleFallback)
			{
				var fb:LibraryItem = ruffleFallback;
				ruffleFallback = null;
				var as3:Boolean = fb.info && fb.info.as3 === true;
				// this file plays with the built-in engine from now on (long-press → Engine to change)
				settings.engineFiles[fb.name] = as3 ? Settings.ENGINE_AIR : Settings.ENGINE_AVM1;
				settings.save();
				listScreen.refreshCards();
				if (!pendingOpen) pendingOpen = fb;
			}
			if (ruffleUnsupported)
			{
				ruffleUnsupported = false;
				listScreen.refreshCards();
				if (tab == 1 && !inLayoutScreen) settingsScreen.refresh();
				if (ruffleUnsupportedWhy.indexOf("native") == 0)
					snack.show("Ruffle can't run on this phone (its graphics are too old) — the built-in engines are used now.", 8000);
				else
					snack.show("Ruffle doesn't work with this phone's WebView — the built-in engines are used now. " +
						"Update \"Android System WebView\" in Google Play to use Ruffle.", 8000);
			}
			if (pendingOpen)
			{
				var next:LibraryItem = pendingOpen;
				pendingOpen = null;
				play(next);
			}
		}

		private function onUncaught(e:UncaughtErrorEvent):void
		{
			e.preventDefault();
			reportError("Error", e.error);
		}

		private function reportError(where:String, err:*):void
		{
			Log.error(where, err);
			var msg:String;
			if (err is Error) msg = (err as Error).errorID + ": " + (err as Error).message;
			else if (err is ErrorEvent) msg = ErrorEvent(err).text;
			else msg = String(err);
			var stk:String = "";
			try { if (err is Error && (err as Error).getStackTrace()) stk = "\n" + (err as Error).getStackTrace().split("\n").slice(0, 8).join("\n"); } catch (e2:Error) {}
			snack.show(where + ": " + msg + stk, 10000);
			setChildIndex(snack, numChildren - 1);
		}

		// ================================================================= "Open with"

		private var pendingOpen:LibraryItem;

		private function onInvoke(e:InvokeEvent):void
		{
			checkOpened();
		}

		/** a .swf opened from another app: OpenActivity (native) has copied it to the cache */
		private function checkOpened():void
		{
			if (!nativeExt || !nativeExt.available) return;
			var path:String = nativeExt.takeOpened();
			if (!path) return;
			if (path.indexOf("error") == 0)
			{
				Log.write("open with: " + path);
				snack.show("Couldn't open the file: " + path.substr(7));
				return;
			}
			var it:LibraryItem;
			try { it = new LibraryItem(new File(path)); } catch (err:Error) { return; }
			it.temporary = true;
			Log.write("open with: " + it.name + " (" + it.size + " bytes)");
			if (player)
			{
				// another game is running: close it, then open this one
				pendingOpen = it;
				player.close();
				return;
			}
			if (ruffleOn && nativeExt.closeRuffle())
			{
				// the same for a game in Ruffle: "ruffle_closed" opens this one
				pendingOpen = it;
				return;
			}
			ruffleOn = false;
			play(it);
		}

		private function onPlayerClosed(e:Event):void
		{
			Log.write("player closed");
			if (player && player.parent) removeChild(player);
			player = null;
			if (pendingOpen)
			{
				var next:LibraryItem = pendingOpen;
				pendingOpen = null;
				play(next);
				return;
			}
			stage.frameRate = 60;
			stage.quality = StageQuality.HIGH;
			ui.visible = true;
			setPortrait();
			layout();
		}

		private function setLandscape():void
		{
			try { stage.setAspectRatio(StageAspectRatio.LANDSCAPE); } catch (e:Error) {}
			if (nativeExt && nativeExt.available) nativeExt.setOrientation("game");
			try { stage.displayState = StageDisplayState.FULL_SCREEN_INTERACTIVE; } catch (e2:Error) {}
			try { NativeApplication.nativeApplication.systemIdleMode = SystemIdleMode.KEEP_AWAKE; } catch (e3:Error) {}
		}

		private function setPortrait():void
		{
			if (Capabilities.manufacturer.indexOf("Android") < 0) return;
			try { stage.displayState = StageDisplayState.NORMAL; } catch (e:Error) {}
			// the file list: portrait or landscape as the phone is held, never upside down
			if (nativeExt && nativeExt.available)
			{
				try { stage.setAspectRatio(StageAspectRatio.ANY); } catch (e1:Error) {}
				nativeExt.setOrientation("list");
			}
			else try { stage.setAspectRatio(StageAspectRatio.PORTRAIT); } catch (e2:Error) {}
			try { NativeApplication.nativeApplication.systemIdleMode = SystemIdleMode.NORMAL; } catch (e3:Error) {}
		}

		// ================================================================= navigation

		private function showTab(i:int):void
		{
			tab = i;
			inLayoutScreen = false;
			nav.selected = i;
			listScreen.visible = i == 0;
			settingsScreen.visible = i == 1;
			aboutScreen.visible = i == 2;
			layoutScreen.visible = false;
			if (i == 1) settingsScreen.refresh();
			appBar.configure(i == 0 ? "Bwekh Player" : i == 1 ? "Settings" : "About", false, i == 0);
			layout();
		}

		private function showLayoutScreen(show:Boolean):void
		{
			inLayoutScreen = show;
			layoutScreen.visible = show;
			settingsScreen.visible = !show && tab == 1;
			if (show) layoutScreen.refresh();
			else settingsScreen.refresh();
			appBar.configure(show ? "Gamepad layout" : "Settings", show, false);
			layout();
		}

		private var lastBackEvent:int = -1000;

		private function onKeyUp(e:KeyboardEvent):void
		{
			if (e.keyCode != Keyboard.BACK) return;
			if (player && player.isDispatchingVirtualKey) return;
			e.preventDefault();
		}

		private function onKey(e:KeyboardEvent):void
		{
			if (e.keyCode != Keyboard.BACK) return;
			if (player && player.isDispatchingVirtualKey) return;
			e.preventDefault();
			e.stopImmediatePropagation();
			// the same press can arrive through both listeners (stage and application)
			var t:int = getTimer();
			if (t - lastBackEvent < 150) return;
			lastBackEvent = t;
			Log.write("key: back" + (dialogs.isOpen ? " (dialog)" : player ? " (player)" : tab != 0 ? " (tab " + tab + ")" : " (list)"));
			if (dialogs.isOpen) dialogs.cancel();
			else if (player) player.onBack();
			else if (inLayoutScreen) showLayoutScreen(false);
			else if (tab != 0) showTab(0);
			else
			{
				// leave only on a second press within 2 seconds
				var now:int = getTimer();
				if (now - lastBackAt < 2000) NativeApplication.nativeApplication.exit();
				else
				{
					lastBackAt = now;
					snack.show("Press back again to exit", 2000);
				}
			}
		}

		private function onActivate(e:Event):void
		{
			Log.write("app: activate");
			// back from Ruffle (its "closed" event normally comes first)
			if (ruffleOn && getTimer() - ruffleAt > 1500) onRuffleClosed();
			checkOpened();
			if (player)
			{
				player.onActivate();
				return;
			}
			lib.setDir(resolveListDir());
			updateExtraDirs();
			lib.scan();
			if (tab == 1 && !inLayoutScreen) settingsScreen.refresh();
		}

		private function onDeactivate(e:Event):void
		{
			Log.write("app: deactivate");
			Log.flush(); // the app may be killed in the background
			if (player) player.onDeactivate();
		}

		// ================================================================= layout

		/** Insets change after rotation / full screen with a delay, so poll them a few times a second. */
		private var lastBackAt:int = -100000;
		private var laidW:Number = -1;
		private var laidH:Number = -1;

		private function checkInsets(e:Event):void
		{
			// a rotation doesn't always send a resize event (seen when one game follows another)
			if (stage && (stage.stageWidth != laidW || stage.stageHeight != laidH))
			{
				laidW = stage.stageWidth;
				laidH = stage.stageHeight;
				layout();
				if (player) player.refreshLayout();
			}
			if (++insetTick % 15 != 0) return;
			var n:Object = nativeExt.insets();
			if (n.l != insets.l || n.t != insets.t || n.r != insets.r || n.b != insets.b)
			{
				insets = n;
				layout();
				if (player) player.refreshLayout();
			}
		}

		public function getInsets():Object
		{
			return insets;
		}

		private function layout():void
		{
			if (!stage) return;
			var w:Number = stage.stageWidth;
			var h:Number = stage.stageHeight;
			graphics.clear();
			graphics.beginFill(M.BG);
			graphics.drawRect(0, 0, w, h);
			graphics.endFill();

			// Android 15+ draws apps under the status and navigation bars ("edge-to-edge"):
			// the red bar and the white bottom bar extend under them, content stays clear.
			var ins:Object = insets;
			var top:Number = ins.t + AppBar.barHeight;
			var navH:Number = BottomNav.barHeight + ins.b;
			var bodyH:Number = Math.max(10, h - top - navH);
			appBar.layout(w, ins.t);
			nav.y = h - navH;
			nav.layout(w, ins.b);

			for each (var s:Sprite in [listScreen, settingsScreen, layoutScreen, aboutScreen])
				s.y = top;
			// one broken screen must not stop the others from being laid out
			safe(function():void { listScreen.layout(w, bodyH); });
			safe(function():void { settingsScreen.layout(w, bodyH); });
			safe(function():void { layoutScreen.layout(w, bodyH); });
			safe(function():void { aboutScreen.layout(w, bodyH); });
			safe(function():void { dialogs.layout(w, h, ins); });
			safe(function():void { snack.layout(w, player ? h : h - navH); });
		}

		private function safe(f:Function):void
		{
			try
			{
				f();
			}
			catch (e:Error)
			{
				trace("layout error: " + e.message);
			}
		}
	}
}
