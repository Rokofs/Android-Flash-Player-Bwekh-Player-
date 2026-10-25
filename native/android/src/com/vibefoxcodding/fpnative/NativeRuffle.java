package com.vibefoxcodding.fpnative;

import android.app.Activity;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.os.Build;

/**
 * Native Ruffle (rs.ruffle.PlayerActivity, Rust, no WebView) from the app's side.
 * It plays in its own process; its events come back as broadcasts and go on to ActionScript
 * like the WebView player's ("ruffle_closed", "ruffle_pad", "ruffle_crashed", "ruffle_error").
 */
public final class NativeRuffle {

	private static final String ACTION_EVENT = "com.vibefoxcodding.fpnative.RUFFLE_EVENT";
	private static final String ACTION_CLOSE = "com.vibefoxcodding.fpnative.RUFFLE_CLOSE";
	private static final String ACTIVITY = "rs.ruffle.PlayerActivity";

	private static Boolean available;
	private static boolean listening = false;
	/** a game is open in it (between start and "ruffle_closed") */
	static volatile boolean open = false;

	private NativeRuffle() {}

	/** OpenGL ES 3 or newer (Ruffle draws with it) */
	static boolean glesOk(Context c) {
		try {
			android.app.ActivityManager am = (android.app.ActivityManager) c.getSystemService(Context.ACTIVITY_SERVICE);
			return am.getDeviceConfigurationInfo().reqGlEsVersion >= 0x30000;
		} catch (Throwable t) {
			return true;
		}
	}

	/** Android 5+ and libruffle_android.so in this APK */
	static boolean available(Context c) {
		if (available != null) return available;
		boolean ok = false;
		try {
			if (Build.VERSION.SDK_INT >= 21) {
				ClassLoader cl = c.getClassLoader();
				String lib = null;
				if (cl instanceof dalvik.system.BaseDexClassLoader)
					lib = ((dalvik.system.BaseDexClassLoader) cl).findLibrary("ruffle_android");
				ok = lib != null && Class.forName(ACTIVITY, false, cl) != null;
			}
		} catch (Throwable t) {
			ok = false;
		}
		available = ok;
		return ok;
	}

	static void start(Activity a, String path, String config) throws Exception {
		listen(a);
		Intent i = new Intent();
		i.setClassName(a.getPackageName(), ACTIVITY);
		i.putExtra("path", path);
		i.putExtra("config", config);
		open = true;
		a.startActivity(i);
	}

	static boolean close(Context c) {
		boolean was = open;
		try {
			Intent i = new Intent(ACTION_CLOSE);
			i.setPackage(c.getPackageName());
			c.sendBroadcast(i);
		} catch (Throwable t) { }
		return was;
	}

	private static void listen(Context c) {
		if (listening) return;
		Context app = c.getApplicationContext();
		BroadcastReceiver r = new BroadcastReceiver() {
			@Override
			public void onReceive(Context ctx, Intent i) {
				String code = i.getStringExtra("code");
				String level = i.getStringExtra("level");
				if (code == null) return;
				if ("ruffle_closed".equals(code)) open = false;
				FPNativeContext fc = FPNativeContext.current;
				if (fc != null) fc.send(code, level);
			}
		};
		IntentFilter f = new IntentFilter(ACTION_EVENT);
		if (Build.VERSION.SDK_INT >= 33) app.registerReceiver(r, f, 4 /* RECEIVER_NOT_EXPORTED */);
		else app.registerReceiver(r, f);
		listening = true;
	}
}
