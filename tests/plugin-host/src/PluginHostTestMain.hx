import plugin.host.PluginHost;

/** The bridge must work without linking or initializing the legacy platform. */
class PluginHostTestMain {
	static function require(condition:Bool, message:String):Void {
		if (!condition) throw message;
	}

	static function main():Int {
		var text = "Olá にほん 😀 é";
		PluginHost.install(function(operation:Int, token:String, a:String, b:String, c:String):String {
			require(operation == 7 && token == text && a == "にほん" && b == "😀" && c == "Olá", "callback UTF-8 arguments");
			return token + a + b + c;
		});
		var saved = PluginHost.call(7, text, "にほん", "😀", "Olá");
		require(saved == text + "にほん😀Olá", "callback UTF-8 result");
		PluginHost.install(function(operation:Int, token:String, a:String, b:String, c:String):String {
			throw "Erro にほん 😀";
		});
		var failure = "";
		try PluginHost.call(0, "", "", "", "") catch (error:String) failure = error;
		require(failure.indexOf("Erro にほん 😀") >= 0, "callback error lost Unicode or did not reach the caller");
		PluginHost.install(function(operation:Int, token:String, a:String, b:String, c:String):String return text);
		require(PluginHost.call(0, "", "", "", "") == text, "replacement retained the failed callback");
		require(saved == text + "にほん😀Olá", "borrowed callback result changed after replacement");
		PluginHost.close();
		PluginHost.close();
		failure = "";
		try PluginHost.call(0, "", "", "", "") catch (error:String) failure = error;
		require(failure == "Exosuit plugin host is not installed", "shutdown did not unregister before closing the callback");
		PluginHost.install(function(operation:Int, token:String, a:String, b:String, c:String):String return "reinstalled");
		require(PluginHost.call(0, "", "", "", "") == "reinstalled", "callback did not reinstall after shutdown");
		PluginHost.close();
		Sys.println("PASS: independent plugin host, Unicode callbacks/errors, borrowed results, replacement, shutdown, and reinstall");
		return 0;
	}
}
