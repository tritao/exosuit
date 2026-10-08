package feedback;

/** Presentation shared by notification history and transient status messages. */
class NotificationText {
	public static function severity(entry:Notification):String return switch entry.kind {
		case Information: "Information";
		case Warning: "Warning";
		case Error: "Error";
	};

	public static function summary(entry:Notification, limit:Int = 120):String {
		var line = entry.message.split("\n")[0];
		return line.length > limit ? line.substr(0, limit - 1) + "…" : line;
	}

	public static function details(entry:Notification):String {
		return severity(entry) + (entry.source == "" ? "" : " · " + entry.source)
			+ " · " + time(entry) + "\n\n" + entry.message;
	}

	public static function time(entry:Notification):String {
		var seconds = Std.int(Math.floor(entry.createdAt % 86400));
		return pad(Std.int(seconds / 3600)) + ":" + pad(Std.int(seconds / 60) % 60) + ":" + pad(seconds % 60) + " UTC";
	}

	static function pad(value:Int):String return value < 10 ? "0" + value : Std.string(value);

	/** Only the diagnostic emitted by our runtime enables a retained-report action. */
	public static function crashPid(entry:Notification):Null<Int> {
		var command = ~/Inspect a retained core with: coredumpctl debug ([0-9]+)/;
		if (!command.match(entry.message)) return null;
		var pid = Std.parseInt(command.matched(1));
		return pid != null && pid > 0 ? pid : null;
	}
}
