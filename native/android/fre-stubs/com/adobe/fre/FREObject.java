package com.adobe.fre;

public class FREObject {
	public String getAsString() throws IllegalStateException, FRETypeMismatchException, FREInvalidObjectException, FREWrongThreadException { return null; }
	public int getAsInt() throws IllegalStateException, FRETypeMismatchException, FREInvalidObjectException, FREWrongThreadException { return 0; }
	public boolean getAsBool() throws IllegalStateException, FRETypeMismatchException, FREInvalidObjectException, FREWrongThreadException { return false; }
	public static FREObject newObject(String v) throws FREWrongThreadException { return null; }
	public static FREObject newObject(int v) throws FREWrongThreadException { return null; }
	public static FREObject newObject(boolean v) throws FREWrongThreadException { return null; }
}
