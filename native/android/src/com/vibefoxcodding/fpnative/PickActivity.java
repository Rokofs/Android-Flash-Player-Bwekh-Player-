package com.vibefoxcodding.fpnative;

import android.app.Activity;
import android.content.ContentResolver;
import android.content.Context;
import android.content.Intent;
import android.database.Cursor;
import android.net.Uri;
import android.os.Bundle;

import java.io.File;
import java.io.InputStream;

/**
 * Invisible helper activity: shows the system "choose a file" chooser (any installed
 * file manager), copies the chosen file into the destination folder and reports back
 * to ActionScript through FPNativeContext.
 */
public class PickActivity extends Activity {

	static final String EXTRA_DEST = "fp_dest";
	private static final int REQ = 4712;
	private String dest;

	@Override
	protected void onCreate(Bundle state) {
		super.onCreate(state);
		dest = getIntent().getStringExtra(EXTRA_DEST);
		if (state != null) {
			dest = state.getString(EXTRA_DEST, dest);
			return; // chooser already shown before re-creation
		}
		try {
			Intent get = new Intent(Intent.ACTION_GET_CONTENT);
			get.setType("*/*");
			get.addCategory(Intent.CATEGORY_OPENABLE);
			startActivityForResult(Intent.createChooser(get, "SWF"), REQ);
		} catch (Throwable t) {
			report("pick_error", String.valueOf(t));
			finish();
		}
	}

	@Override
	protected void onSaveInstanceState(Bundle out) {
		super.onSaveInstanceState(out);
		out.putString(EXTRA_DEST, dest);
	}

	@Override
	protected void onActivityResult(int requestCode, int resultCode, Intent data) {
		super.onActivityResult(requestCode, resultCode, data);
		if (requestCode != REQ) return;
		final Uri uri = (resultCode == RESULT_OK && data != null) ? data.getData() : null;
		if (uri == null) {
			report("pick_cancel", "");
			finish();
			return;
		}
		final Context app = getApplicationContext();
		final String target = dest;
		new Thread(new Runnable() {
			public void run() {
				try {
					report("pick", copy(app, uri, target));
				} catch (Throwable t) {
					report("pick_error", String.valueOf(t));
				}
			}
		}).start();
		finish();
		overridePendingTransition(0, 0);
	}

	private static String copy(Context c, Uri uri, String destDir) throws Exception {
		ContentResolver cr = c.getContentResolver();
		File dir = (destDir == null || destDir.length() == 0)
				? new File(c.getExternalFilesDir(null), "swf")
				: new File(destDir);
		dir.mkdirs();

		String name = displayName(cr, uri);
		File out = unique(dir, FPNativeContext.safeName(name));
		InputStream in = cr.openInputStream(uri);
		if (in == null) throw new Exception("Cannot open " + uri);
		try {
			FPNativeContext.copyStream(in, out);
		} finally {
			in.close();
		}
		return out.getAbsolutePath();
	}

	static String displayName(ContentResolver cr, Uri uri) {
		Cursor cur = null;
		try {
			cur = cr.query(uri, new String[] { "_display_name" }, null, null, null);
			if (cur != null && cur.moveToFirst()) {
				int i = cur.getColumnIndex("_display_name");
				if (i >= 0) {
					String n = cur.getString(i);
					if (n != null && n.length() > 0) return n;
				}
			}
		} catch (Throwable t) {
			// fall back to the URI
		} finally {
			if (cur != null) cur.close();
		}
		String seg = uri.getLastPathSegment();
		if (seg != null) {
			int slash = seg.lastIndexOf('/');
			if (slash >= 0) seg = seg.substring(slash + 1);
			int colon = seg.lastIndexOf(':');
			if (colon >= 0) seg = seg.substring(colon + 1);
		}
		return seg == null || seg.length() == 0 ? "file.swf" : seg;
	}

	private static File unique(File dir, String name) {
		File f = new File(dir, name);
		if (!f.exists()) return f;
		String base = name;
		String ext = "";
		int dot = name.lastIndexOf('.');
		if (dot > 0) {
			base = name.substring(0, dot);
			ext = name.substring(dot);
		}
		for (int i = 2; i < 1000; i++) {
			f = new File(dir, base + " (" + i + ")" + ext);
			if (!f.exists()) return f;
		}
		return new File(dir, base + "-" + System.currentTimeMillis() + ext);
	}

	private static void report(String code, String level) {
		FPNativeContext ctx = FPNativeContext.current;
		if (ctx != null) ctx.send(code, level);
	}
}
