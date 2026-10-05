package plugin;

import plugin.host.PluginHost;

class DynamicHostRouter {
	static inline final CONNECT = 0;
	static inline final DOCUMENT_TEXT = 1;
	static inline final REPLACE_SELECTIONS = 2;
	static inline final ADD_PANEL = 3;
	static inline final SET_PANEL_TEXT = 4;
	static inline final SUBSCRIBE_DOCUMENT = 5;
	static inline final CONFIGURATION = 6;
	static inline final ADD_STATUS_ITEM = 7;
	static inline final SET_STATUS_ITEM_TEXT = 8;
	static inline final ADD_DECORATION = 9;
	static var nextToken:Int = 1;
	static var owners:Int = 0;
	static var registrations:Map<Int, DynamicHostRegistration> = [];
	static var activating:Null<DynamicHostRegistration>;

	public static function initialize():Void {
		if (owners == 0) PluginHost.install(dispatch);
		owners++;
	}

	public static function shutdown():Void {
		if (owners == 0) return;
		owners--;
		if (owners != 0) return;
		PluginHost.close();
		activating = null;
		registrations = [];
	}

	public static function begin(context:PluginContext, plugin:DynamicPlugin):Void {
		if (activating != null) throw "nested dynamic plugin activation is not supported";
		var registration:Null<DynamicHostRegistration> = null;
		for (candidate in registrations)
			if (candidate.context == context && candidate.plugin == plugin) registration = candidate;
		if (registration == null) registration = new DynamicHostRegistration(nextToken++, context, plugin);
		activating = registration;
	}

	public static function end():Void
		activating = null;

	static function dispatch(operation:Int, token:String, a:String, b:String, c:String):String {
		try {
			return "ok:" + dispatchCall(operation, token, a, b, c);
		} catch (error:Dynamic) {
			return "error:" + Std.string(error);
		}
	}

	static function dispatchCall(operation:Int, token:String, a:String, b:String, c:String):String {
		if (operation == CONNECT) {
			var registration = activating;
			if (registration == null || registration.context.id != a) throw 'plugin "$a" is not being activated';
			if (!registrations.exists(registration.token)) {
				registrations.set(registration.token, registration);
				registration.context.own(function() {
					registrations.remove(registration.token);
				});
			}
			return Std.string(registration.token);
		}
		var registration = registrations.get(Std.parseInt(token));
		if (registration == null) throw "dynamic plugin host token is invalid or retired";
		var api = registration.context.api;
		return switch operation {
			case DOCUMENT_TEXT: api.activeDocumentText();
			case REPLACE_SELECTIONS:
				var replaced = api.replaceSelections(a);
				replaced ? "1" : "0";
			case ADD_PANEL:
				api.addPanel(a, b, c);
				"1";
			case SET_PANEL_TEXT: api.setPanelText(a, b) ? "1" : "0";
			case SUBSCRIBE_DOCUMENT:
				var functionName = a, plugin = registration.plugin;
				api.onDocumentChanged(event -> plugin.callStringArg(functionName, event.document.buffer.text));
				"1";
			case CONFIGURATION: configuration(api.configuration(), a);
			case ADD_STATUS_ITEM:
				api.addStatusItem(a, b, parseInt(c));
				"1";
			case SET_STATUS_ITEM_TEXT: api.setStatusItemText(a, b) ? "1" : "0";
			case ADD_DECORATION:
				var range = b.split(":"), color = parseInt(c);
				if (range.length != 3) throw "decoration range must be line:start:end";
				api.addDecoration(a, parseInt(range[0]), parseInt(range[1]), parseInt(range[2]), color);
				"1";
			default: throw 'unknown dynamic editor API operation $operation';
		};
	}

	static function parseInt(value:String):Int {
		return Std.parseInt(value);
	}

	static function configuration(settings:config.Settings, name:String):String
		return switch name {
			case "editor.fontPath": settings.fontPath;
			case "editor.fontSize": Std.string(settings.fontSize);
			case "editor.tabWidth": Std.string(settings.tabWidth);
			case "editor.insertSpaces": Std.string(settings.insertSpaces);
			case "search.maxResults": Std.string(settings.searchMaxResults);
			default: "";
		};
}
