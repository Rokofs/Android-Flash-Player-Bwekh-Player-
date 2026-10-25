package com.vibefoxcodding.fpnative;

import android.app.Activity;
import android.content.ClipData;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.pm.ProviderInfo;
import android.net.Uri;
import android.os.Build;
import android.os.Environment;
import android.provider.Settings;
import android.view.View;
import android.view.WindowInsets;

import com.adobe.fre.FREContext;
import com.adobe.fre.FREFunction;
import com.adobe.fre.FREObject;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.HashMap;
import java.util.Map;

/**
 * Functions available to ActionScript via ExtensionContext.call(name, ...):
 *   isSupported()                       -> Boolean
 *   sdkInt()                            -> int
 *   getExternalFilesDir()               -> String  (…/Android/data/<package>/files)
 *   pickFile(destDir)                   -> Boolean (async: status "pick" / "pick_cancel" / "pick_error")
 *   share(path, mime, title)            -> Boolean
 *   hasAllFilesAccess()                 -> Boolean
 *   requestAllFilesAccess()             -> Boolean (opens system settings / permission dialog)
 *   setupWebViews()                     -> int (WebViews found; lets them play sound without a tap)
 *   setRenderScale(scale, fixTouch)     -> String (render the AIR surface smaller; 1 = full size)
 *   lastTouch()                         -> String "count,x,y,viewW,viewH" (raw touch, for calibration)
 *   takeOpened()                        -> String (path of a .swf opened via "Open with" (OpenActivity); "" if none)
 *   playRuffle(path, configJson)        -> Boolean (native Ruffle (rs.ruffle.PlayerActivity) or RuffleActivity; status "ruffle_closed" when it's gone)
 *   closeRuffle()                       -> Boolean
 */
public class FPNativeContext extends FREContext {

	/** Context that receives results from PickActivity. */
	static volatile FPNativeContext current;

	public FPNativeContext() {
		current = this;
	}

	void send(String code, String level) {
		try {
			dispatchStatusEventAsync(code, level == null ? "" : level);
		} catch (Throwable t) {
			// context already disposed
		}
	}

	@Override
	public void dispose() {
		if (current == this) current = null;
	}

	@Override
	public Map<String, FREFunction> getFunctions() {
		Map<String, FREFunction> m = new HashMap<String, FREFunction>();

		m.put("isSupported", new FREFunction() {
			public FREObject call(FREContext ctx, FREObject[] args) {
				return bool(true);
			}
		});

		m.put("sdkInt", new FREFunction() {
			public FREObject call(FREContext ctx, FREObject[] args) {
				try { return FREObject.newObject(Build.VERSION.SDK_INT); } catch (Throwable t) { return null; }
			}
		});

		m.put("getExternalFilesDir", new FREFunction() {
			public FREObject call(FREContext ctx, FREObject[] args) {
				String path = "";
				try {
					File dir = getActivity().getExternalFilesDir(null);
					if (dir != null) {
						dir.mkdirs();
						path = dir.getAbsolutePath();
					}
				} catch (Throwable t) {
					path = "";
				}
				return str(path);
			}
		});

		m.put("pickFile", new FREFunction() {
			public FREObject call(FREContext ctx, FREObject[] args) {
				try {
					String dest = arg(args, 0);
					Activity a = getActivity();
					Intent i = new Intent(a, PickActivity.class);
					i.putExtra(PickActivity.EXTRA_DEST, dest);
					a.startActivity(i);
					return bool(true);
				} catch (Throwable t) {
					send("pick_error", String.valueOf(t));
					return bool(false);
				}
			}
		});

		m.put("share", new FREFunction() {
			public FREObject call(FREContext ctx, FREObject[] args) {
				try {
					return bool(share(arg(args, 0), arg(args, 1), arg(args, 2)));
				} catch (Throwable t) {
					send("share_error", String.valueOf(t));
					return bool(false);
				}
			}
		});

		m.put("hasAllFilesAccess", new FREFunction() {
			public FREObject call(FREContext ctx, FREObject[] args) {
				try {
					if (Build.VERSION.SDK_INT >= 30) return bool(Environment.isExternalStorageManager());
					if (Build.VERSION.SDK_INT >= 23) {
						return bool(getActivity().checkSelfPermission("android.permission.READ_EXTERNAL_STORAGE")
								== PackageManager.PERMISSION_GRANTED);
					}
					return bool(true);
				} catch (Throwable t) {
					return bool(false);
				}
			}
		});

		m.put("setRenderScale", new FREFunction() {
			public FREObject call(FREContext ctx, FREObject[] args) {
				try {
					final float scale = (float) Double.parseDouble(arg(args, 0));
					final boolean fixTouch = "1".equals(arg(args, 1));
					final Activity a = getActivity();
					final String[] res = { "" };
					Runnable r = new Runnable() {
						public void run() {
							try { res[0] = setRenderScale(a.getWindow().getDecorView(), scale, fixTouch); }
							catch (Throwable t) { res[0] = "error " + t; }
						}
					};
					if (android.os.Looper.myLooper() == android.os.Looper.getMainLooper()) r.run();
					else a.runOnUiThread(r);
					return str(res[0]);
				} catch (Throwable t) {
					return str("error " + t);
				}
			}
		});

		// "list": portrait or landscape as the phone is held (never upside down; follows the
		// system's auto-rotate switch); "game": landscape, both sides
		m.put("setOrientation", new FREFunction() {
			public FREObject call(FREContext ctx, FREObject[] args) {
				try {
					String mode = arg(args, 0);
					int o = "game".equals(mode) ? android.content.pm.ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
						: android.content.pm.ActivityInfo.SCREEN_ORIENTATION_USER;
					getActivity().setRequestedOrientation(o);
					return bool(true);
				} catch (Throwable t) {
					return bool(false);
				}
			}
		});

		m.put("playRuffle", new FREFunction() {
			public FREObject call(FREContext ctx, FREObject[] args) {
				try {
					Activity a = getActivity();
					// native Ruffle (Rust) when this phone can run it; the WebView one otherwise
					if (NativeRuffle.available(a)) {
						if (!NativeRuffle.glesOk(a)) {
							// the graphics are too old for Ruffle (the WebView one fails there too):
							// the app plays it with its own engine
							send("ruffle_unsupported", "native: OpenGL ES 3 missing");
							send("ruffle_closed", "");
							return bool(true);
						}
						NativeRuffle.start(a, arg(args, 0), arg(args, 1));
						return bool(true);
					}
					Intent i = new Intent(a, RuffleActivity.class);
					i.putExtra(RuffleActivity.EXTRA_PATH, arg(args, 0));
					i.putExtra(RuffleActivity.EXTRA_CONFIG, arg(args, 1));
					a.startActivity(i);
					return bool(true);
				} catch (Throwable t) {
					send("ruffle_error", String.valueOf(t));
					return bool(false);
				}
			}
		});

		m.put("closeRuffle", new FREFunction() {
			public FREObject call(FREContext ctx, FREObject[] args) {
				boolean was = RuffleActivity.current != null;
				RuffleActivity.closeCurrent();
				try { if (NativeRuffle.close(getActivity())) was = true; } catch (Throwable t) { }
				return bool(was);
			}
		});

		m.put("takeOpened", new FREFunction() {
			public FREObject call(FREContext ctx, FREObject[] args) {
				String p = OpenActivity.pendingPath;
				OpenActivity.pendingPath = null;
				return str(p == null ? "" : p);
			}
		});

		m.put("lastTouch", new FREFunction() {
			public FREObject call(FREContext ctx, FREObject[] args) {
				return str(touchCount + "," + lastTouchX + "," + lastTouchY + "," + touchViewW + "," + touchViewH);
			}
		});

		m.put("getInsets", new FREFunction() {
			public FREObject call(FREContext ctx, FREObject[] args) {
				try {
					return str(insets());
				} catch (Throwable t) {
					return str("0,0,0,0");
				}
			}
		});

		m.put("setupWebViews", new FREFunction() {
			public FREObject call(FREContext ctx, FREObject[] args) {
				try {
					final Activity a = getActivity();
					final int[] found = { 0 };
					Runnable r = new Runnable() {
						public void run() {
							try { found[0] = setupWebViews(a.getWindow().getDecorView()); } catch (Throwable t) { }
						}
					};
					if (android.os.Looper.myLooper() == android.os.Looper.getMainLooper()) r.run();
					else a.runOnUiThread(r);
					return FREObject.newObject(found[0]);
				} catch (Throwable t) {
					try { return FREObject.newObject(-1); } catch (Throwable t2) { return null; }
				}
			}
		});

		m.put("requestAllFilesAccess", new FREFunction() {
			public FREObject call(FREContext ctx, FREObject[] args) {
				try {
					Activity a = getActivity();
					if (Build.VERSION.SDK_INT >= 30) {
						try {
							Intent i = new Intent("android.settings.MANAGE_APP_ALL_FILES_ACCESS_PERMISSION",
									Uri.parse("package:" + a.getPackageName()));
							a.startActivity(i);
						} catch (Throwable t) {
							a.startActivity(new Intent("android.settings.MANAGE_ALL_FILES_ACCESS_PERMISSION"));
						}
					} else if (Build.VERSION.SDK_INT >= 23) {
						a.requestPermissions(new String[] {
								"android.permission.READ_EXTERNAL_STORAGE",
								"android.permission.WRITE_EXTERNAL_STORAGE" }, 4711);
					}
					return bool(true);
				} catch (Throwable t) {
					return bool(false);
				}
			}
		});

		return m;
	}

	// ------------------------------------------------------------------ web views

	/** StageWebView's WebView: allow audio without a user gesture (Ruffle's sound), keep it focusable. */
	// ------------------------------------------------------------------ render size

	static volatile int touchCount = 0;
	static volatile float lastTouchX = -1, lastTouchY = -1;
	static volatile int touchViewW = 0, touchViewH = 0;

	/**
	 * Render the AIR surface at a smaller size (scale < 1); the display hardware stretches it
	 * to the screen for free, like games do. scale >= 1 goes back to full size.
	 * fixTouch: shrink touch coordinates to the smaller surface (if AIR doesn't do it).
	 * Returns a short report for the log.
	 */
	private static String setRenderScale(View root, final float scale, final boolean fixTouch) {
		java.util.ArrayList<android.view.SurfaceView> list = new java.util.ArrayList<android.view.SurfaceView>();
		findSurfaces(root, list);
		StringBuilder sb = new StringBuilder();
		for (final android.view.SurfaceView sv : list) {
			int vw = sv.getWidth(), vh = sv.getHeight();
			if (scale < 0.999f && vw <= vh) {
				// still the portrait layout (the screen is turning): the app asks again a bit later
				sb.append("wait: ").append(vw).append("x").append(vh).append("; ");
				continue;
			}
			if (scale >= 0.999f || vw <= 0 || vh <= 0) {
				sv.getHolder().setSizeFromLayout();
				sv.setOnTouchListener(null);
				sb.append(sv.getClass().getSimpleName()).append(" full ").append(vw).append("x").append(vh).append("; ");
				continue;
			}
			int w = Math.max(16, Math.round(vw * scale)), h = Math.max(16, Math.round(vh * scale));
			sv.getHolder().setFixedSize(w, h);
			sv.setOnTouchListener(new View.OnTouchListener() {
				public boolean onTouch(View v, android.view.MotionEvent e) {
					touchCount++;
					lastTouchX = e.getX();
					lastTouchY = e.getY();
					touchViewW = v.getWidth();
					touchViewH = v.getHeight();
					if (!fixTouch) return false; // AIR maps the touch itself
					android.view.MotionEvent c = android.view.MotionEvent.obtain(e);
					android.graphics.Matrix mx = new android.graphics.Matrix();
					// AIR draws its full-size stage from the BOTTOM-left of the smaller surface
					// (OpenGL origin), so the visible part is the bottom of the stage
					mx.setScale(scale, scale);
					mx.postTranslate(0, v.getHeight() * (1 - scale));
					c.transform(mx);
					boolean done = false;
					try { done = v.onTouchEvent(c); } finally { c.recycle(); }
					return true;
				}
			});
			sb.append(sv.getClass().getSimpleName()).append(" ").append(vw).append("x").append(vh)
				.append(" -> ").append(w).append("x").append(h).append(fixTouch ? " (touch fix)" : "").append("; ");
		}
		if (list.isEmpty()) sb.append("no surface found");
		return sb.toString();
	}

	private static void findSurfaces(View v, java.util.List<android.view.SurfaceView> out) {
		if (v == null) return;
		if (v instanceof android.view.SurfaceView) out.add((android.view.SurfaceView) v);
		if (v instanceof android.view.ViewGroup) {
			android.view.ViewGroup g = (android.view.ViewGroup) v;
			for (int i = 0; i < g.getChildCount(); i++) findSurfaces(g.getChildAt(i), out);
		}
	}

	private static int setupWebViews(View v) {
		if (v == null) return 0;
		int n = 0;
		if (v instanceof android.webkit.WebView) {
			android.webkit.WebView w = (android.webkit.WebView) v;
			try {
				if (Build.VERSION.SDK_INT >= 17) w.getSettings().setMediaPlaybackRequiresUserGesture(false);
			} catch (Throwable t) { }
			n++;
		}
		if (v instanceof android.view.ViewGroup) {
			android.view.ViewGroup g = (android.view.ViewGroup) v;
			for (int i = 0; i < g.getChildCount(); i++) n += setupWebViews(g.getChildAt(i));
		}
		return n;
	}

	// ------------------------------------------------------------------ insets

	/**
	 * How much of the AIR view is covered by the status bar, navigation bar and display cutout,
	 * as "left,top,right,bottom" in pixels. Measured against the content view itself, so it is
	 * correct both for edge-to-edge windows (Android 15+) and for classic ones (then it's 0).
	 */
	private String insets() {
		Activity a = getActivity();
		View content = a.findViewById(android.R.id.content);
		View decor = a.getWindow().getDecorView();
		if (content == null || decor == null || Build.VERSION.SDK_INT < 23) return "0,0,0,0";
		WindowInsets wi = decor.getRootWindowInsets();
		if (wi == null) return "0,0,0,0";
		int sl, st, sr, sb;
		if (Build.VERSION.SDK_INT >= 30) {
			android.graphics.Insets in = wi.getInsets(WindowInsets.Type.systemBars() | WindowInsets.Type.displayCutout());
			sl = in.left; st = in.top; sr = in.right; sb = in.bottom;
		} else {
			sl = wi.getSystemWindowInsetLeft(); st = wi.getSystemWindowInsetTop();
			sr = wi.getSystemWindowInsetRight(); sb = wi.getSystemWindowInsetBottom();
		}
		int[] loc = new int[2];
		content.getLocationOnScreen(loc);
		int[] dloc = new int[2];
		decor.getLocationOnScreen(dloc);
		int vx = loc[0] - dloc[0], vy = loc[1] - dloc[1];
		int vw = content.getWidth(), vh = content.getHeight();
		int dw = decor.getWidth(), dh = decor.getHeight();
		int l = Math.max(0, sl - vx);
		int t = Math.max(0, st - vy);
		int r = Math.max(0, (vx + vw) - (dw - sr));
		int b = Math.max(0, (vy + vh) - (dh - sb));
		return l + "," + t + "," + r + "," + b;
	}

	// ------------------------------------------------------------------ share

	private boolean share(String path, String mime, String title) throws Exception {
		Activity a = getActivity();
		File src = new File(path);
		if (!src.isFile()) return false;

		// Copy into cache/share so the provider only ever exposes that folder.
		File dir = new File(a.getCacheDir(), ShareProvider.DIR);
		dir.mkdirs();
		File[] old = dir.listFiles();
		if (old != null) for (File f : old) f.delete();
		File copy = new File(dir, safeName(src.getName()));
		copyFile(src, copy);

		String authority = providerAuthority(a);
		Uri uri = Uri.parse("content://" + authority + "/" + Uri.encode(copy.getName()));

		Intent send = new Intent(Intent.ACTION_SEND);
		send.setType(mime == null || mime.length() == 0 ? "application/octet-stream" : mime);
		send.putExtra(Intent.EXTRA_STREAM, uri);
		send.setClipData(ClipData.newRawUri(copy.getName(), uri));
		send.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);

		Intent chooser = Intent.createChooser(send, title == null || title.length() == 0 ? "Share" : title);
		chooser.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
		a.startActivity(chooser);
		return true;
	}

	static String providerAuthority(Context c) {
		try {
			ProviderInfo info = c.getPackageManager().getProviderInfo(
					new ComponentName(c, ShareProvider.class), 0);
			if (info != null && info.authority != null) return info.authority;
		} catch (Throwable t) {
			// fall through
		}
		return c.getPackageName() + ".share";
	}

	// ------------------------------------------------------------------ helpers

	static String safeName(String name) {
		if (name == null || name.length() == 0) name = "file.swf";
		name = name.replaceAll("[\\\\/:*?\"<>|\\p{Cntrl}]", "_").trim();
		if (name.length() == 0 || name.equals(".") || name.equals("..")) name = "file.swf";
		return name;
	}

	static void copyFile(File src, File dst) throws Exception {
		InputStream in = new FileInputStream(src);
		try {
			copyStream(in, dst);
		} finally {
			in.close();
		}
	}

	static void copyStream(InputStream in, File dst) throws Exception {
		OutputStream out = new FileOutputStream(dst);
		try {
			byte[] buf = new byte[64 * 1024];
			int n;
			while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
		} finally {
			out.close();
		}
	}

	private static String arg(FREObject[] args, int i) {
		try {
			if (args != null && args.length > i && args[i] != null) return args[i].getAsString();
		} catch (Throwable t) {
			// ignore
		}
		return "";
	}

	private static FREObject bool(boolean v) {
		try { return FREObject.newObject(v); } catch (Throwable t) { return null; }
	}

	private static FREObject str(String v) {
		try { return FREObject.newObject(v); } catch (Throwable t) { return null; }
	}
}
