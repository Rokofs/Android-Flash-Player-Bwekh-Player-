package com.vibefoxcodding.fpnative;

import android.app.Activity;
import android.content.ContentResolver;
import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import android.os.Bundle;

import java.io.File;
import java.io.InputStream;

/**
 * "Open with" target for .swf files. AIR's own activity must not receive VIEW intents
 * (it crashes on them before any of our code runs), so this invisible activity takes the
 * file, copies it into the app's cache (cache/opened, emptied first), remembers the path
 * for ActionScript (FPNativeContext.takeOpened) and brings the player to the front.
 */
public class OpenActivity extends Activity {

	static volatile String pendingPath = null;

	@Override
	protected void onCreate(Bundle state) {
		super.onCreate(state);
		final Uri uri = getIntent() != null ? getIntent().getData() : null;
		final Context app = getApplicationContext();
		if (uri == null) {
			launchPlayer(app);
			finish();
			return;
		}
		// copy right here, while this activity still holds the permission to read the URI
		try {
			pendingPath = copy(app, uri);
		} catch (Throwable t) {
			pendingPath = "error: " + t;
		}
		launchPlayer(app);
		finish();
		overridePendingTransition(0, 0);
	}

	private static void launchPlayer(Context c) {
		try {
			Intent i = c.getPackageManager().getLaunchIntentForPackage(c.getPackageName());
			if (i == null) return;
			i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED);
			c.startActivity(i);
			// if the player was already running, it may not get a new intent: tell it directly
			FPNativeContext ctx = FPNativeContext.current;
			if (ctx != null) ctx.send("opened", "");
		} catch (Throwable t) {
			// nothing more we can do
		}
	}

	private static String copy(Context c, Uri uri) throws Exception {
		ContentResolver cr = c.getContentResolver();
		File dir = new File(c.getCacheDir(), "opened");
		dir.mkdirs();
		File[] old = dir.listFiles();
		if (old != null) for (File f : old) f.delete();
		String name = FPNativeContext.safeName(PickActivity.displayName(cr, uri));
		if (!name.toLowerCase().endsWith(".swf")) name = name + ".swf";
		File out = new File(dir, name);
		InputStream in = cr.openInputStream(uri);
		if (in == null) throw new Exception("Cannot open " + uri);
		try {
			FPNativeContext.copyStream(in, out);
		} finally {
			in.close();
		}
		return out.getAbsolutePath();
	}
}
