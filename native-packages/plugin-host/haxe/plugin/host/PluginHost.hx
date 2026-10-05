package plugin.host;

import plugin.host.ffi.PluginHostApi;
import plugin.host.ffi.PluginHostTypes.DispatchCallback;

/** Owns the retained callback independently of legacy platform initialization/shutdown. */
class PluginHost {
	static var dispatchCallback:Null<DispatchCallback>;

	public static function install(dispatch:(Int, String, String, String, String)->String):Void {
		var replacement = new DispatchCallback(dispatch);
		PluginHostApi.exosuit_plugin_host_install(replacement);
		var retired = dispatchCallback;
		dispatchCallback = replacement;
		if (retired != null) retired.close();
	}

	public static function close():Void {
		PluginHostApi.exosuit_plugin_host_install(null);
		var retired = dispatchCallback;
		dispatchCallback = null;
		if (retired != null) retired.close();
	}

	public static function call(operation:Int, token:String, a:String, b:String, c:String):String {
		var callback = dispatchCallback;
		if (callback == null) throw "Exosuit plugin host is not installed";
		var result = PluginHostApi.exosuit_plugin_host_call(operation, token, a, b, c);
		var error = callback.takeError();
		if (error != null) throw error.toString();
		return result;
	}
}
