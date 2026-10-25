package rs.ruffle;

import android.app.AlertDialog;
import android.app.NativeActivity;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.DialogInterface;
import android.content.Intent;
import android.content.IntentFilter;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.drawable.ColorDrawable;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.View;
import android.view.Window;
import android.view.WindowManager;
import android.widget.PopupWindow;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.InputStream;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * Ruffle (native, Rust: libruffle_android.so, built from native/ruffle-rs) playing a SWF.
 *
 * Android's own NativeActivity runs the Rust code (android-activity), which calls the methods
 * below by name (see native/ruffle-rs/src/java.rs), so their names and signatures must stay.
 * The class name must stay too: the Rust JNI functions are Java_rs_ruffle_PlayerActivity_*.
 *
 * It runs in its own process (":ruffle" in the manifest): a crash or the memory a game takes
 * stays there, and the process ends with the game. It talks to the app with broadcasts
 * (com.vibefoxcodding.fpnative.NativeRuffle): "ruffle_closed", "ruffle_pad", "ruffle_crashed".
 *
 * On top of the game (in small windows of their own: the game draws on the whole window):
 * the gamepad from the app's settings and a pause button; Back opens the pause menu.
 */
public class PlayerActivity extends NativeActivity {

	public static final String EXTRA_PATH = "path";
	public static final String EXTRA_CONFIG = "config";
	/** broadcast actions (package-local), see NativeRuffle */
	public static final String ACTION_EVENT = "com.vibefoxcodding.fpnative.RUFFLE_EVENT";
	public static final String ACTION_CLOSE = "com.vibefoxcodding.fpnative.RUFFLE_CLOSE";

	private static final String TAG = "BwekhRuffle";

	static {
		System.loadLibrary("ruffle_android");
	}

	// ------------------------------------------------------------------ used by Rust

	/** a Rust object (the event loop's sender), kept here by the Rust code */
	@SuppressWarnings("unused")
	private long eventLoopHandle = 0;

	private File swf;
	private final int[] loc = new int[2];

	@SuppressWarnings("unused")
	private int getSurfaceWidth() {
		View d = getWindow().getDecorView();
		return Math.max(1, d.getWidth());
	}

	@SuppressWarnings("unused")
	private int getSurfaceHeight() {
		View d = getWindow().getDecorView();
		return Math.max(1, d.getHeight());
	}

	@SuppressWarnings("unused")
	private int[] getLocInWindow() {
		loc[0] = 0;
		loc[1] = 0;
		return loc;
	}

	@SuppressWarnings("unused")
	private byte[] getSwfBytes() {
		if (swf == null) return null;
		InputStream in = null;
		try {
			in = new FileInputStream(swf);
			ByteArrayOutputStream out = new ByteArrayOutputStream((int) Math.max(1024, swf.length()));
			byte[] buf = new byte[65536];
			int n;
			while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
			return out.toByteArray();
		} catch (Throwable t) {
			Log.e(TAG, "can't read " + swf, t);
			return null;
		} finally {
			try { if (in != null) in.close(); } catch (Throwable t) { }
		}
	}

	@SuppressWarnings("unused")
	private String getSwfUri() {
		return swf != null ? Uri.fromFile(swf).toString() : "";
	}

	@SuppressWarnings("unused")
	private String getTraceOutput() {
		return null;
	}

	@SuppressWarnings("unused")
	private String getAndroidDataStorageDir() {
		File dir = new File(getFilesDir(), "ruffle/shared_objects");
		if (!dir.exists()) dir.mkdirs();
		return dir.getAbsolutePath();
	}

	/** Ruffle can't play here (no usable OpenGL ES 3): the app uses its own engine */
	@SuppressWarnings("unused")
	private void fail(String why) {
		Log.e(TAG, "Ruffle can't run: " + why);
		tell("ruffle_unsupported", "native: " + why);
		ui.post(new Runnable() { public void run() { finish(); } });
	}

	/** the quality from the app's settings: "low" / "medium" / "high" / "best" */
	@SuppressWarnings("unused")
	private String getQuality() {
		return cfg.optString("quality", "high");
	}

	/** a line for the app's log: fps and where the time goes (every 3 s) */
	@SuppressWarnings("unused")
	private void perf(String line) {
		tell("ruffle_perf", line);
	}

	/** the app's render height (Settings; 0 = the screen's): Rust draws at that size, the screen scales it */
	@SuppressWarnings("unused")
	private int getRenderHeight() {
		return cfg.optInt("renderRes", 0);
	}

	/** Ruffle's right-click menu: not offered (the pause menu has what's needed) */
	@SuppressWarnings("unused")
	private void showContextMenu(String[] items) {
	}

	@SuppressWarnings("unused")
	private void navigateToUrl(String url) {
	}

	private static native void nativeInit(CrashCallback callback);
	private native void keydown(String keyTag);
	private native void keyup(String keyTag);
	private native void requestContextMenu();
	private native void runContextMenuCallback(int index);
	private native void clearContextMenu();
	/** Bwekh: a Flash key code down (1) / up (0) */
	private native void keyCode(int code, int down);
	/** Bwekh: 0 = stop (pause menu), 1 = go on */
	private native void setPlaying(int playing);

	public interface CrashCallback {
		void onCrash(String message);
	}

	// ------------------------------------------------------------------ life

	private final Handler ui = new Handler(Looper.getMainLooper());
	private JSONObject cfg = new JSONObject();
	private boolean restarting = false;
	private boolean closedSent = false;
	private boolean nativeReady = false;

	@Override
	protected void onCreate(Bundle state) {
		Intent in = getIntent();
		String path = in.getStringExtra(EXTRA_PATH);
		swf = path != null ? new File(path) : null;
		try { cfg = new JSONObject(in.getStringExtra(EXTRA_CONFIG)); } catch (Throwable t) { cfg = new JSONObject(); }

		nativeInit(new CrashCallback() {
			public void onCrash(final String message) {
				Log.e(TAG, "Ruffle crashed: " + message);
				String m = message == null ? "" : message;
				tell("ruffle_crashed", "crash: " + (m.length() > 600 ? m.substring(0, 600) : m));
				ui.post(new Runnable() { public void run() { finish(); } });
			}
		});
		nativeReady = true;

		requestWindowFeature(Window.FEATURE_NO_TITLE);
		Window w = getWindow();
		w.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON | WindowManager.LayoutParams.FLAG_FULLSCREEN);
		if (Build.VERSION.SDK_INT >= 28) {
			WindowManager.LayoutParams lp = w.getAttributes();
			lp.layoutInDisplayCutoutMode = 1; // SHORT_EDGES
			w.setAttributes(lp);
		}
		super.onCreate(state);
		hideBars();

		if (swf == null || !swf.isFile()) {
			tell("ruffle_error", "no file: " + path);
			finish();
			return;
		}

		IntentFilter f = new IntentFilter(ACTION_CLOSE);
		try {
			if (Build.VERSION.SDK_INT >= 33) registerReceiver(closer, f, 4 /* RECEIVER_NOT_EXPORTED */);
			else registerReceiver(closer, f);
		} catch (Throwable t) { }

		// the overlay needs the window on screen
		getWindow().getDecorView().post(new Runnable() {
			public void run() { buildOverlay(); }
		});
	}

	private final BroadcastReceiver closer = new BroadcastReceiver() {
		@Override
		public void onReceive(Context c, Intent i) {
			finish();
		}
	};

	@Override
	protected void onResume() {
		super.onResume();
		hideBars();
	}

	@Override
	public void onWindowFocusChanged(boolean hasFocus) {
		super.onWindowFocusChanged(hasFocus);
		if (hasFocus) hideBars();
	}

	@Override
	protected void onPause() {
		releaseAll();
		super.onPause();
		if (isFinishing()) tellClosed();
	}

	@Override
	protected void onDestroy() {
		releaseAll();
		dismissOverlay();
		try { unregisterReceiver(closer); } catch (Throwable t) { }
		tellClosed();
		super.onDestroy();
		if (!restarting) {
			// the game's process ends with it (its memory, its threads); the app is in another one
			ui.postDelayed(new Runnable() {
				public void run() { android.os.Process.killProcess(android.os.Process.myPid()); }
			}, 400);
		}
	}

	@SuppressWarnings("deprecation")
	@Override
	public void onBackPressed() {
		showMenu();
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

	private void tellClosed() {
		if (closedSent || restarting) return;
		closedSent = true;
		tell("ruffle_closed", "");
	}

	/** an event for the app (another process): see NativeRuffle */
	private void tell(String code, String level) {
		try {
			Intent i = new Intent(ACTION_EVENT);
			i.setPackage(getPackageName());
			i.putExtra("code", code);
			i.putExtra("level", level == null ? "" : level);
			sendBroadcast(i);
		} catch (Throwable t) { }
	}

	// ------------------------------------------------------------------ pause menu

	private boolean paused = false;
	private AlertDialog menu;

	private void showMenu() {
		if (menu != null && menu.isShowing()) return;
		releaseAll();
		paused = true;
		if (nativeReady) try { setPlaying(0); } catch (Throwable t) { }
		final boolean padAvailable = pad != null && cfg.optJSONObject("pad") != null
				&& cfg.optJSONObject("pad").optBoolean("available", true);
		final List<String> items = new ArrayList<String>();
		final List<String> acts = new ArrayList<String>();
		items.add("Continue"); acts.add("cont");
		if (padAvailable) { items.add(padShown ? "Hide gamepad" : "Show gamepad"); acts.add("pad"); }
		items.add("Restart"); acts.add("restart");
		items.add("Exit"); acts.add("exit");
		String name = cfg.optString("name", swf != null ? swf.getName() : "");
		AlertDialog.Builder b = new AlertDialog.Builder(this, AlertDialog.THEME_DEVICE_DEFAULT_DARK);
		b.setTitle("Paused" + (name.length() > 0 ? " \u2014 " + name : ""));
		b.setItems(items.toArray(new String[0]), new DialogInterface.OnClickListener() {
			public void onClick(DialogInterface d, int which) {
				String a = acts.get(which);
				if ("pad".equals(a)) {
					showPad(!padShown);
					tell("ruffle_pad", padShown ? "1" : "0");
				} else if ("restart".equals(a)) {
					restart();
					return;
				} else if ("exit".equals(a)) {
					finish();
					return;
				}
				resumeGame();
			}
		});
		b.setOnCancelListener(new DialogInterface.OnCancelListener() {
			public void onCancel(DialogInterface d) { resumeGame(); }
		});
		menu = b.create();
		try {
			// no system bars coming back with the dialog
			menu.getWindow().setFlags(WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE, WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE);
			menu.show();
			menu.getWindow().getDecorView().setSystemUiVisibility(getWindow().getDecorView().getSystemUiVisibility());
			menu.getWindow().clearFlags(WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE);
		} catch (Throwable t) {
			resumeGame();
		}
	}

	private void resumeGame() {
		paused = false;
		if (nativeReady) try { setPlaying(1); } catch (Throwable t) { }
		hideBars();
		activity();
	}

	private void restart() {
		restarting = true;
		Intent i = new Intent(getIntent());
		i.addFlags(Intent.FLAG_ACTIVITY_NO_ANIMATION);
		finish();
		startActivity(i);
	}

	// ------------------------------------------------------------------ overlay: gamepad + pause button

	private JSONObject pad;
	private boolean padShown = false;
	private PopupWindow dpadWin, btnWin, pauseWin;
	private PadView dpadView, btnView;
	private PauseView pauseView;
	private float dp = 1, R, BR, BD, EXT;
	private final int[] dpadCodes = new int[4];
	private final List<int[]> btnPos = new ArrayList<int[]>();
	private final List<String> btnLabels = new ArrayList<String>();
	private final List<Integer> btnCodes = new ArrayList<Integer>();
	/** key code -> fingers on it */
	private final Map<Integer, Integer> held = new HashMap<Integer, Integer>();

	private void buildOverlay() {
		if (isFinishing()) return;
		dp = getResources().getDisplayMetrics().density;
		View anchor = getWindow().getDecorView();
		pad = cfg.optJSONObject("pad");
		if (pad != null) {
			try {
				float sc = (float) pad.optDouble("scale", 1);
				if (!(sc > 0)) sc = 1;
				R = 68 * sc * dp; BR = 30 * sc * dp; BD = 50 * sc * dp;
				EXT = Math.max(R * 1.15f, BD + BR * 1.3f);
				JSONArray d = pad.optJSONArray("dpad");
				for (int i = 0; i < 4; i++) {
					JSONObject k = d != null ? d.optJSONObject(i) : null;
					dpadCodes[i] = k != null ? k.optInt("kc", 37 + i) : new int[] {38, 40, 37, 39}[i];
				}
				int[][] pos = { {0, 1}, {1, 0}, {-1, 0}, {0, -1} }; // bottom, right, left, top — as in the app
				JSONArray bs = pad.optJSONArray("buttons");
				for (int j = 0; j < 4 && bs != null; j++) {
					JSONObject b = bs.optJSONObject(j);
					if (b == null) continue;
					btnPos.add(pos[j]);
					btnLabels.add(b.optString("label", "?"));
					btnCodes.add(b.optInt("kc", 32));
				}
				float op = (float) pad.optDouble("opacity", 0.5);
				if (!(op > 0)) op = 0.5f;
				int size = Math.round(EXT * 2);
				dpadView = new PadView(this, true);
				btnView = new PadView(this, false);
				dpadView.setAlpha(op);
				btnView.setAlpha(op);
				dpadWin = popup(dpadView, size, size);
				btnWin = popup(btnView, size, size);
				padShown = pad.optBoolean("show", true);
			} catch (Throwable t) {
				Log.e(TAG, "gamepad", t);
				pad = null;
			}
		}
		pauseView = new PauseView(this);
		int ps = Math.round(48 * dp);
		pauseWin = popup(pauseView, ps, ps);
		try {
			int m = Math.round(12 * dp);
			pauseWin.showAtLocation(anchor, Gravity.TOP | Gravity.RIGHT, m, m);
		} catch (Throwable t) { Log.e(TAG, "pause button", t); }
		showPad(padShown);
		activity();
	}

	private PopupWindow popup(View v, int w, int h) {
		PopupWindow p = new PopupWindow(v, w, h, false);
		p.setBackgroundDrawable(new ColorDrawable(Color.TRANSPARENT));
		p.setTouchable(true);
		p.setOutsideTouchable(false);
		p.setClippingEnabled(false);
		p.setSplitTouchEnabled(true);
		p.setAnimationStyle(0);
		return p;
	}

	private void showPad(boolean on) {
		padShown = on && pad != null;
		releaseAll();
		if (dpadWin == null) return;
		View anchor = getWindow().getDecorView();
		if (!padShown) {
			dpadWin.dismiss();
			btnWin.dismiss();
			return;
		}
		try {
			int margin = Math.round(20 * dp);
			int reach = Math.round(Math.max(R, BD + BR));
			int ext = Math.round(EXT);
			// bottom corners: centers at margin + reach from the edges
			int off = margin + reach - ext;
			boolean swap = pad.optBoolean("swap", false);
			PopupWindow left = swap ? btnWin : dpadWin, right = swap ? dpadWin : btnWin;
			if (!left.isShowing()) left.showAtLocation(anchor, Gravity.BOTTOM | Gravity.LEFT, off, off);
			if (!right.isShowing()) right.showAtLocation(anchor, Gravity.BOTTOM | Gravity.RIGHT, off, off);
		} catch (Throwable t) { Log.e(TAG, "gamepad", t); }
	}

	private void dismissOverlay() {
		for (PopupWindow p : new PopupWindow[] { dpadWin, btnWin, pauseWin }) {
			try { if (p != null) p.dismiss(); } catch (Throwable t) { }
		}
		try { if (menu != null) menu.dismiss(); } catch (Throwable t) { }
	}

	// the pause button fades after 5 s without touches on it or the pad
	private final Runnable idle = new Runnable() {
		public void run() { if (pauseView != null) { pauseView.idle = true; pauseView.invalidate(); } }
	};

	private void activity() {
		if (pauseView == null) return;
		pauseView.idle = false;
		pauseView.invalidate();
		ui.removeCallbacks(idle);
		ui.postDelayed(idle, 5000);
	}

	// ------------------------------------------------------------------ keys

	private void press(int code, boolean down) {
		Integer n = held.get(code);
		int c = n == null ? 0 : n;
		if (down) {
			held.put(code, c + 1);
			if (c == 0) sendKey(code, true);
		} else {
			if (c <= 1) {
				held.remove(code);
				if (c == 1) sendKey(code, false);
			} else held.put(code, c - 1);
		}
	}

	private void sendKey(final int code, final boolean down) {
		if (!nativeReady || paused) return;
		try { keyCode(code, down ? 1 : 0); } catch (Throwable t) { }
		// key repeat while held, as a keyboard does (games that wait for keyPress events)
		ui.removeCallbacks(repeats.get(code) != null ? repeats.get(code) : NOOP);
		if (down) {
			Runnable r = new Runnable() {
				public void run() {
					Integer n = held.get(code);
					if (n == null || n <= 0 || paused) return;
					try { keyCode(code, 1); } catch (Throwable t) { }
					ui.postDelayed(this, 50);
				}
			};
			repeats.put(code, r);
			ui.postDelayed(r, 500);
		} else repeats.remove(code);
	}

	private static final Runnable NOOP = new Runnable() { public void run() { } };
	private final Map<Integer, Runnable> repeats = new HashMap<Integer, Runnable>();

	private void releaseAll() {
		for (Integer code : new ArrayList<Integer>(held.keySet())) {
			ui.removeCallbacks(repeats.get(code) != null ? repeats.get(code) : NOOP);
			if (nativeReady) try { keyCode(code, 0); } catch (Throwable t) { }
		}
		held.clear();
		repeats.clear();
		if (dpadView != null) { dpadView.clearPointers(); dpadView.invalidate(); }
		if (btnView != null) { btnView.clearPointers(); btnView.invalidate(); }
	}

	/** the d-pad (4 directions, diagonals = two keys) or the buttons, in a window of its own */
	private class PadView extends View {
		private final boolean isDpad;
		private final Paint fill = new Paint(Paint.ANTI_ALIAS_FLAG);
		private final Paint line = new Paint(Paint.ANTI_ALIAS_FLAG);
		private final Paint text = new Paint(Paint.ANTI_ALIAS_FLAG);
		/** pointer id -> codes it holds */
		private final Map<Integer, int[]> pointers = new HashMap<Integer, int[]>();

		PadView(Context c, boolean isDpad) {
			super(c);
			this.isDpad = isDpad;
			line.setStyle(Paint.Style.STROKE);
			line.setStrokeWidth(2 * dp);
			line.setColor(Color.argb(153, 255, 255, 255));
			text.setColor(Color.WHITE);
			text.setTextAlign(Paint.Align.CENTER);
			text.setFakeBoldText(true);
		}

		void clearPointers() { pointers.clear(); }

		private boolean on(int code) {
			Integer n = held.get(code);
			return n != null && n > 0;
		}

		@Override
		protected void onDraw(Canvas cv) {
			float c = EXT;
			if (isDpad) {
				fill.setColor(Color.argb(89, 0, 0, 0));
				cv.drawCircle(c, c, R, fill);
				cv.drawCircle(c, c, R, line);
				String[] arrows = { "\u25B2", "\u25BC", "\u25C0", "\u25B6" };
				int[][] dirs = { {0, -1}, {0, 1}, {-1, 0}, {1, 0} };
				text.setTextSize(R * 0.36f);
				for (int i = 0; i < 4; i++) {
					float x = c + dirs[i][0] * R * 0.58f, y = c + dirs[i][1] * R * 0.58f;
					fill.setColor(on(dpadCodes[i]) ? Color.argb(242, 255, 64, 129) : Color.argb(51, 255, 255, 255));
					cv.drawCircle(x, y, R * 0.42f, fill);
					cv.drawText(arrows[i], x, y - (text.descent() + text.ascent()) / 2, text);
				}
			} else {
				text.setTextSize(15 * dp * (BR / (30 * dp)));
				for (int j = 0; j < btnPos.size(); j++) {
					float x = c + btnPos.get(j)[0] * BD, y = c + btnPos.get(j)[1] * BD;
					fill.setColor(on(btnCodes.get(j)) ? Color.argb(242, 255, 64, 129) : Color.argb(89, 0, 0, 0));
					cv.drawCircle(x, y, BR, fill);
					cv.drawCircle(x, y, BR, line);
					cv.drawText(btnLabels.get(j), x, y - (text.descent() + text.ascent()) / 2, text);
				}
			}
		}

		private int[] codesAt(float x, float y) {
			float c = EXT;
			if (isDpad) {
				float px = x - c, py = y - c;
				double dist = Math.sqrt(px * px + py * py);
				if (dist < R * 0.22 || dist > R * 2.5) return new int[0];
				float t = R * 0.38f;
				List<Integer> res = new ArrayList<Integer>();
				if (py < -t) res.add(dpadCodes[0]);
				if (py > t) res.add(dpadCodes[1]);
				if (px < -t) res.add(dpadCodes[2]);
				if (px > t) res.add(dpadCodes[3]);
				if (res.isEmpty()) {
					if (Math.abs(px) > Math.abs(py)) res.add(px < 0 ? dpadCodes[2] : dpadCodes[3]);
					else res.add(py < 0 ? dpadCodes[0] : dpadCodes[1]);
				}
				int[] r = new int[res.size()];
				for (int i = 0; i < r.length; i++) r[i] = res.get(i);
				return r;
			}
			int best = -1;
			double bestD = 1e9;
			for (int j = 0; j < btnPos.size(); j++) {
				double dx = x - (c + btnPos.get(j)[0] * BD), dy = y - (c + btnPos.get(j)[1] * BD);
				double d = Math.sqrt(dx * dx + dy * dy);
				if (d < bestD) { bestD = d; best = j; }
			}
			return best >= 0 && bestD <= BR * 1.35 ? new int[] { btnCodes.get(best) } : new int[0];
		}

		private void apply(int id, int[] now) {
			int[] old = pointers.get(id);
			if (old == null) old = new int[0];
			for (int o : old) if (!has(now, o)) press(o, false);
			for (int n : now) if (!has(old, n)) press(n, true);
			if (now.length == 0) pointers.remove(id); else pointers.put(id, now);
			invalidate();
		}

		private boolean has(int[] a, int v) {
			for (int x : a) if (x == v) return true;
			return false;
		}

		@Override
		public boolean onTouchEvent(MotionEvent ev) {
			activity();
			int act = ev.getActionMasked();
			switch (act) {
				case MotionEvent.ACTION_DOWN:
				case MotionEvent.ACTION_POINTER_DOWN: {
					int i = ev.getActionIndex();
					apply(ev.getPointerId(i), codesAt(ev.getX(i), ev.getY(i)));
					break;
				}
				case MotionEvent.ACTION_MOVE:
					for (int i = 0; i < ev.getPointerCount(); i++) {
						int id = ev.getPointerId(i);
						if (pointers.containsKey(id) || isDpad) apply(id, codesAt(ev.getX(i), ev.getY(i)));
					}
					break;
				case MotionEvent.ACTION_UP:
				case MotionEvent.ACTION_POINTER_UP: {
					int i = ev.getActionIndex();
					apply(ev.getPointerId(i), new int[0]);
					break;
				}
				case MotionEvent.ACTION_CANCEL:
					for (Integer id : new ArrayList<Integer>(pointers.keySet())) apply(id, new int[0]);
					break;
			}
			return true;
		}
	}

	/** the round pause button (top right); fades when not used */
	private class PauseView extends View {
		boolean idle = false;
		private final Paint p = new Paint(Paint.ANTI_ALIAS_FLAG);

		PauseView(Context c) { super(c); }

		@Override
		protected void onDraw(Canvas cv) {
			float w = getWidth(), h = getHeight();
			int a = idle ? 25 : 255;
			p.setColor(Color.argb(idle ? 10 : 102, 0, 0, 0));
			cv.drawCircle(w / 2, h / 2, Math.min(w, h) / 2, p);
			p.setColor(Color.argb(a, 255, 255, 255));
			float bw = 6 * dp, bh = 20 * dp, gap = 3 * dp;
			cv.drawRect(w / 2 - gap - bw, h / 2 - bh / 2, w / 2 - gap, h / 2 + bh / 2, p);
			cv.drawRect(w / 2 + gap, h / 2 - bh / 2, w / 2 + gap + bw, h / 2 + bh / 2, p);
		}

		@Override
		public boolean onTouchEvent(MotionEvent ev) {
			if (ev.getActionMasked() == MotionEvent.ACTION_UP) {
				if (idle) activity();
				else showMenu();
			}
			return true;
		}
	}
}
