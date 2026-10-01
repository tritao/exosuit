package app;

import platform.Native;
import platform.Platform;

class NativeStringTestMain {
	static function require(condition:Bool, message:String):Void {
		if (!condition) throw message;
	}

	static function main():Int {
		Platform.startHeadless();
		var text = "Olá にほん 😀 é";
		require(Native.clipboard_set(text) && Native.clipboard_get() == text, "clipboard UTF-8 round trip");
		var saved = Native.clipboard_get();
		require(Native.clipboard_set("replacement") && saved == text, "borrowed native results must be copied");
		Native.plugin_api_install(function(operation:Int, token:String, a:String, b:String, c:String):String {
			require(operation == 7 && token == text && a == "にほん" && b == "😀" && c == "Olá", "callback UTF-8 arguments");
			return token + a + b + c;
		});
		require(Native.plugin_api_call(7, text, "にほん", "😀", "Olá") == text + "にほん😀Olá", "callback UTF-8 result");
		Native.plugin_api_install(function(operation:Int, token:String, a:String, b:String, c:String):String {
			throw "Erro にほん 😀";
		});
		var failure = "";
		try Native.plugin_api_call(0, "", "", "", "") catch (error:String) failure = error;
		require(failure.indexOf("Erro にほん 😀") >= 0, "callback error must preserve Unicode and reach the caller");
		Native.plugin_api_install(function(operation:Int, token:String, a:String, b:String, c:String):String return text);
		require(Native.plugin_api_call(0, "", "", "", "") == text, "replacement must retire the failed callback");
		require(!Native.window_destroy(0) && Native.last_error() == "invalid or stale window handle", "native error result");
		var process = Native.process_create("unused", "");
		require(process != 0 && !Native.process_set_environment(process, "にほん=😀", ""), "reject invalid environment key");
		require(Native.last_error() == "invalid process environment key: にほん=😀", "native error must preserve Unicode");
		var longKey = "=" + StringTools.rpad("", "😀", 200);
		require(!Native.process_set_environment(process, longKey, ""), "reject long environment key");
		var diagnostic = Native.last_error();
		require(diagnostic.indexOf("invalid process environment key: =") == 0 && diagnostic.indexOf("😀") >= 0,
			"bounded native error must end at a complete UTF-8 scalar");
		require(Native.process_destroy(process), "release error test process");
		Native.shutdown();
		failure = "";
		try Native.plugin_api_call(0, "", "", "", "") catch (error:String) failure = error;
		require(failure == "Pragtical plugin host is not installed", "shutdown must unregister before closing the callback");
		Sys.println("PASS: UTF-8 clipboard, callback arguments/results/errors, replacement, and shutdown");
		return 0;
	}
}
