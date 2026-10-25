package com.vibefoxcodding.fpnative;

import com.adobe.fre.FREContext;
import com.adobe.fre.FREExtension;

/** Entry point of the native extension (named as initializer in extension.xml). */
public class FPNativeExtension implements FREExtension {
	@Override
	public void initialize() {}

	@Override
	public FREContext createContext(String contextType) {
		return new FPNativeContext();
	}

	@Override
	public void dispose() {}
}
