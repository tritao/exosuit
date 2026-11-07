package config;

import workspace.transport.RelayMachineEndpoint;

/** The relay this editor's remote access uses: the `remote/access/relay_url` setting, with the shared Worker as the default. */
class RelayUrl {
	public static inline final SETTING = "remote/access/relay_url";
	/** The Worker Exosuit shipped with. Use your own with relay/worker/scripts/deploy-own.ps1 and docs/mobile/own-relay.md. */
	public static inline final DEFAULT = "https://exosuit-relay.joao-9f7.workers.dev";

	/** The canonical origin (no trailing slash), or null with `error` set when the text is not a usable relay URL. */
	public static function check(text:Null<String>):{origin:Null<String>, error:Null<String>} {
		var value = text == null ? "" : StringTools.trim(text);
		if (value.length == 0)
			return {origin: null, error: "Enter the relay URL"};
		try {
			return {origin: new RelayMachineEndpoint(value, "00000000000000000000000000000000").origin, error: null};
		} catch (error:Dynamic)
			return {origin: null, error: Std.string(error)};
	}

	/** The setting's validation message, or null. An empty value is allowed and means the default. */
	public static function validate(text:Null<String>):Null<String>
		return text == null || StringTools.trim(text).length == 0 ? null : check(text).error;

	/** The origin to use: the setting when it is valid, else the default. */
	public static function resolve(text:Null<String>):String {
		var checked = check(text);
		return checked.origin == null ? DEFAULT : checked.origin;
	}
}
