package com.vibefoxcodding.fpnative;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.database.Cursor;
import android.database.MatrixCursor;
import android.net.Uri;
import android.os.ParcelFileDescriptor;

import java.io.File;
import java.io.FileNotFoundException;

/**
 * Minimal read-only provider that exposes files from cache/share to the app chosen
 * in the share sheet. Not exported; access is granted per-URI by the share intent.
 */
public class ShareProvider extends ContentProvider {

	static final String DIR = "share";

	@Override
	public boolean onCreate() {
		return true;
	}

	private File fileFor(Uri uri) throws FileNotFoundException {
		String name = uri.getLastPathSegment();
		if (name == null) throw new FileNotFoundException();
		File dir = new File(getContext().getCacheDir(), DIR);
		File f = new File(dir, name);
		try {
			if (!f.getCanonicalPath().startsWith(dir.getCanonicalPath() + File.separator)) {
				throw new FileNotFoundException();
			}
		} catch (FileNotFoundException e) {
			throw e;
		} catch (Exception e) {
			throw new FileNotFoundException();
		}
		if (!f.isFile()) throw new FileNotFoundException(name);
		return f;
	}

	@Override
	public ParcelFileDescriptor openFile(Uri uri, String mode) throws FileNotFoundException {
		return ParcelFileDescriptor.open(fileFor(uri), ParcelFileDescriptor.MODE_READ_ONLY);
	}

	@Override
	public Cursor query(Uri uri, String[] projection, String selection, String[] selectionArgs, String sortOrder) {
		File f;
		try {
			f = fileFor(uri);
		} catch (FileNotFoundException e) {
			return null;
		}
		if (projection == null) projection = new String[] { "_display_name", "_size" };
		MatrixCursor c = new MatrixCursor(projection, 1);
		Object[] row = new Object[projection.length];
		for (int i = 0; i < projection.length; i++) {
			if ("_display_name".equals(projection[i])) row[i] = f.getName();
			else if ("_size".equals(projection[i])) row[i] = Long.valueOf(f.length());
			else row[i] = null;
		}
		c.addRow(row);
		return c;
	}

	@Override
	public String getType(Uri uri) {
		String n = uri.getLastPathSegment();
		if (n != null && n.toLowerCase().endsWith(".swf")) return "application/x-shockwave-flash";
		return "application/octet-stream";
	}

	@Override
	public Uri insert(Uri uri, ContentValues values) {
		return null;
	}

	@Override
	public int delete(Uri uri, String selection, String[] selectionArgs) {
		return 0;
	}

	@Override
	public int update(Uri uri, ContentValues values, String selection, String[] selectionArgs) {
		return 0;
	}
}
