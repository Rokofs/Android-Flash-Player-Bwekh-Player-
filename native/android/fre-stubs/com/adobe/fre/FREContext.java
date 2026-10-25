// Compile-time stub of the AIR runtime class (the real one ships with AIR as FlashRuntimeExtensions.jar).
// Not packaged into the extension; only used so javac can resolve signatures.
package com.adobe.fre;

import java.util.Map;

public abstract class FREContext {
	public FREContext() {}
	public abstract Map<String, FREFunction> getFunctions();
	public abstract void dispose();
	public android.app.Activity getActivity() { return null; }
	public void dispatchStatusEventAsync(String code, String level) {}
}
