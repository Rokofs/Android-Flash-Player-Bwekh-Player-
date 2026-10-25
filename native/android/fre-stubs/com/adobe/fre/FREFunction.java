package com.adobe.fre;

public interface FREFunction {
	FREObject call(FREContext context, FREObject[] args);
}
