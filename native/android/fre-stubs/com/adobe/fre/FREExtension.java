package com.adobe.fre;

public interface FREExtension {
	void initialize();
	FREContext createContext(String contextType);
	void dispose();
}
