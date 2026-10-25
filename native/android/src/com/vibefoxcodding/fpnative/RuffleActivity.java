package com.vibefoxcodding.fpnative;

import android.app.Activity;
import android.content.Intent;
import android.content.res.AssetManager;
import android.graphics.Color;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.view.View;
import android.view.Window;
import android.view.WindowManager;
import android.webkit.JavascriptInterface;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceResponse;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;

import java.io.File;
import java.io.FileInputStream;
import java.io.InputStream;
import java.net.URLEncoder;
import java.util.HashMap;
import java.util.Map;

/**
 * Plays a SWF with Ruffle (the web build, bundled in the APK under ruffle/) in a full-screen
 * WebView. Everything is served from https://bwekh.local/ through shouldInterceptRequest:
 *   /ruffle/...  files packaged with the app (assets/ruffle/...)
 *   /game/...    the SWF and the files next to it (games that load other files)
 * Nothing of it goes to the network. Status events to ActionScript: "ruffle_closed",
 * "ruffle_pad" ("1"/"0": the player turned the gamepad on/off), "ruffle_error".
 */
public class RuffleActivity extends Activity {

	static final String EXTRA_PATH = "path";
	static final String EXTRA_CONFIG = "config";
	static final String HOST = "bwekh.local";

	/** the activity on screen, so ActionScript can close it ("Open with" while playing) */
	static volatile RuffleActivity current;

	private WebView web;
	private File gameDir;
	private boolean closedSent = false;

	@Override
	protected void onCreate(Bundle state) {
		super.onCreate(state);
		current = this;
		Window w = getWindow();
		w.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON | WindowManager.LayoutParams.FLAG_FULLSCREEN);
		if (Build.VERSION.SDK_INT >= 28) {
			WindowManager.LayoutParams lp = w.getAttributes();
			lp.layoutInDisplayCutoutMode = 1; // SHORT_EDGES
			w.setAttributes(lp);
		}

		Intent in = getIntent();
		String path = in.getStringExtra(EXTRA_PATH);
		String config = in.getStringExtra(EXTRA_CONFIG);
		if (path == null) { finish(); return; }
		File swf = new File(path);
		gameDir = swf.getParentFile();

		web = new WebView(this);
		web.setBackgroundColor(Color.BLACK);
		WebSettings s = web.getSettings();
		s.setJavaScriptEnabled(true);
		s.setDomStorageEnabled(true);
		s.setMediaPlaybackRequiresUserGesture(false);
		s.setAllowFileAccess(false);
		s.setAllowContentAccess(false);
		s.setSupportZoom(false);
		s.setBuiltInZoomControls(false);
		s.setDisplayZoomControls(false);
		s.setUseWideViewPort(true);
		s.setLoadWithOverviewMode(true);
		s.setSupportMultipleWindows(false);
		web.setVerticalScrollBarEnabled(false);
		web.setHorizontalScrollBarEnabled(false);
		web.setHapticFeedbackEnabled(false);
		web.setLongClickable(false);
		web.setOnLongClickListener(new View.OnLongClickListener() {
			public boolean onLongClick(View v) { return true; }
		});
		web.addJavascriptInterface(new Bridge(), "Bwekh");
		web.setWebChromeClient(new WebChromeClient());
		web.setWebViewClient(new WebViewClient() {
			@Override
			public WebResourceResponse shouldInterceptRequest(WebView view, WebResourceRequest req) {
				WebResourceResponse back = leavingPage(req);
				if (back != null) return back;
				return serve(req.getUrl());
			}

			@SuppressWarnings("deprecation")
			@Override
			public WebResourceResponse shouldInterceptRequest(WebView view, String url) {
				return serve(Uri.parse(url));
			}

			/**
			 * The page's process died (usually out of memory). Without this the system kills the
			 * whole app with it; here only the game closes and the app says why.
			 */
			@Override
			public boolean onRenderProcessGone(WebView view, android.webkit.RenderProcessGoneDetail detail) {
				boolean crashed = false;
				try { crashed = detail != null && detail.didCrash(); } catch (Throwable t) { }
				FPNativeContext ctx = FPNativeContext.current;
				if (ctx != null) ctx.send("ruffle_crashed", crashed ? "crash" : "memory");
				if (web == view) {
					try { setContentView(new View(RuffleActivity.this)); } catch (Throwable t) { }
					try { view.destroy(); } catch (Throwable t) { }
					web = null;
				}
				finish();
				return true;
			}

			@SuppressWarnings("deprecation")
			@Override
			public boolean shouldOverrideUrlLoading(WebView view, String url) {
				// the game page never navigates away (Ruffle is told not to open links)
				Uri u = Uri.parse(url);
				return !HOST.equals(u.getHost());
			}
		});
		setContentView(web);
		hideBars();

		String url;
		try {
			url = "https://" + HOST + "/ruffle/index.html?c=" + URLEncoder.encode(config == null ? "{}" : config, "UTF-8");
		} catch (Exception e) {
			url = "https://" + HOST + "/ruffle/index.html";
		}
		startUrl = url;
		web.loadUrl(url);
	}

	/** the game page's own address (the game starts over when it navigates away, see leavingPage) */
	private String startUrl;

	/**
	 * The game sent its page to another page of its site (arcade games do that after "submitting
	 * score": the site saves it and shows the game again). We have no site, so the game starts over.
	 */
	private WebResourceResponse leavingPage(WebResourceRequest req) {
		try {
			if (startUrl == null || !req.isForMainFrame()) return null;
			Uri u = req.getUrl();
			if (u == null || !HOST.equals(u.getHost())) return null;
			if ("/ruffle/index.html".equals(u.getPath())) return null;
			FPNativeContext ctx = FPNativeContext.current;
			if (ctx != null) ctx.send("ruffle_navigated", u.getPath());
			String html = "<!DOCTYPE html><html><body style='background:#000'><script>location.replace('" + startUrl + "');</script></body></html>";
			Map<String, String> h = new HashMap<String, String>();
			h.put("Cache-Control", "no-store");
			return new WebResourceResponse("text/html", "utf-8", 200, "OK", h,
					new java.io.ByteArrayInputStream(html.getBytes("UTF-8")));
		} catch (Throwable t) {
			return null;
		}
	}

	// ------------------------------------------------------------------ serving files

	private static final Map<String, String> MIME = new HashMap<String, String>();
	static {
		MIME.put("html", "text/html");
		MIME.put("js", "application/javascript");
		MIME.put("css", "text/css");
		MIME.put("wasm", "application/wasm");
		MIME.put("json", "application/json");
		MIME.put("swf", "application/x-shockwave-flash");
		MIME.put("png", "image/png");
		MIME.put("jpg", "image/jpeg");
		MIME.put("jpeg", "image/jpeg");
		MIME.put("gif", "image/gif");
		MIME.put("mp3", "audio/mpeg");
		MIME.put("xml", "text/xml");
		MIME.put("txt", "text/plain");
	}

	private static String mime(String name) {
		int dot = name.lastIndexOf('.');
		String m = dot >= 0 ? MIME.get(name.substring(dot + 1).toLowerCase()) : null;
		return m != null ? m : "application/octet-stream";
	}

	private WebResourceResponse serve(Uri u) {
		if (u == null || !HOST.equals(u.getHost())) return null; // not ours: let it go
		String p = u.getPath();
		if (p == null) p = "/";
		InputStream data = null;
		String name = p;
		try {
			if (p.startsWith("/ruffle/")) {
				name = p.substring(8);
				if (name.length() == 0 || name.contains("..")) name = "index.html";
				data = openAsset("ruffle/" + name);
			} else if (p.startsWith("/game/") && gameDir != null) {
				name = p.substring(6);
				File f = new File(gameDir, name);
				String base = gameDir.getCanonicalPath() + File.separator;
				if (f.getCanonicalPath().startsWith(base) && f.isFile()) data = new FileInputStream(f);
			}
		} catch (Throwable t) {
			data = null;
		}
		WebResourceResponse r;
		Map<String, String> h = new HashMap<String, String>();
		h.put("Access-Control-Allow-Origin", "*");
		h.put("Cache-Control", "no-store");
		if (data == null) {
			r = new WebResourceResponse("text/plain", "utf-8", 404, "Not Found", h,
					new java.io.ByteArrayInputStream(new byte[0]));
		} else {
			r = new WebResourceResponse(mime(name), null, 200, "OK", h, data);
		}
		return r;
	}

	/** AIR packs the app's files into the APK's assets */
	private InputStream openAsset(String name) throws Exception {
		AssetManager am = getAssets();
		try {
			return am.open(name, AssetManager.ACCESS_STREAMING);
		} catch (Exception e) {
			return am.open("assets/" + name, AssetManager.ACCESS_STREAMING);
		}
	}

	// ------------------------------------------------------------------ page <-> app

	private class Bridge {
		@JavascriptInterface
		public void exit() {
			runOnUiThread(new Runnable() {
				public void run() { finish(); }
			});
		}

		@JavascriptInterface
		public void event(String name, String arg) {
			FPNativeContext ctx = FPNativeContext.current;
			if (ctx != null) ctx.send("ruffle_" + name, arg);
		}
	}

	private void js(String code) {
		if (web == null) return;
		try { web.evaluateJavascript("window.bw&&" + code, null); } catch (Throwable t) { }
	}

	@SuppressWarnings("deprecation")
	@Override
	public void onBackPressed() {
		// the page shows its pause menu (Exit is there); if the page doesn't answer, just close
		if (web == null) { finish(); return; }
		try {
			web.evaluateJavascript("(window.bw?(bw.back(),'ok'):'no')", new android.webkit.ValueCallback<String>() {
				public void onReceiveValue(String v) {
					if (v == null || !v.contains("ok")) finish();
				}
			});
		} catch (Throwable t) {
			finish();
		}
	}

	@Override
	protected void onPause() {
		super.onPause();
		js(isFinishing() ? "bw.kill()" : "bw.sleep()");
		if (web != null) web.onPause();
		if (isFinishing()) sendClosed();
	}

	@Override
	protected void onResume() {
		super.onResume();
		if (web != null) {
			web.onResume();
			web.resumeTimers();
		}
		js("bw.resume()");
		hideBars();
	}

	@Override
	public void onWindowFocusChanged(boolean hasFocus) {
		super.onWindowFocusChanged(hasFocus);
		if (hasFocus) hideBars();
	}

	@SuppressWarnings("deprecation")
	private void hideBars() {
		try {
			getWindow().getDecorView().setSystemUiVisibility(
					View.SYSTEM_UI_FLAG_LAYOUT_STABLE
					| View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
					| View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
					| View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
					| View.SYSTEM_UI_FLAG_FULLSCREEN
					| View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY);
		} catch (Throwable t) { }
	}

	private void sendClosed() {
		if (closedSent) return;
		closedSent = true;
		FPNativeContext ctx = FPNativeContext.current;
		if (ctx != null) ctx.send("ruffle_closed", "");
	}

	@Override
	protected void onDestroy() {
		sendClosed();
		if (current == this) current = null;
		if (web != null) {
			try {
				web.evaluateJavascript("window.bw&&bw.kill()", null);
				web.stopLoading();
				web.onPause();
				web.loadUrl("about:blank");
				web.removeAllViews();
				web.destroy();
			} catch (Throwable t) { }
			web = null;
		}
		super.onDestroy();
	}

	/** close the player (ActionScript asks, e.g. another file was opened) */
	static void closeCurrent() {
		final RuffleActivity a = current;
		if (a == null) return;
		a.runOnUiThread(new Runnable() {
			public void run() { a.finish(); }
		});
	}
}
