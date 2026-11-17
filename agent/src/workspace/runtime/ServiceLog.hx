package workspace.runtime;

/**
	Dated lines saying why a service or one of its terminals started or ended, appended to the workspace's
	`service.log` (in its state folder) once the service has opened it, so they survive the service and can be counted
	later. Before that, and in a process with no such file, they go to standard error.
**/
class ServiceLog {
	static var path:Null<String> = null;

	public static function line(message:String):String
		return "[" + now() + "] " + message;

	/** From now on lines go to the file at `file`. */
	public static function open(file:String):Void
		path = file;

	/** Never throws: a log that cannot be written must not stop the service. */
	public static function note(message:String):Void {
		try {
			var file = path;
			if (file != null)
				sys.io.File.appendContent(file, line(message) + "\n");
			else {
				Sys.stderr().writeString(line(message) + "\n");
				Sys.stderr().flush();
			}
		} catch (_:Dynamic) {}
	}

	/** Now in UTC as `YYYY-MM-DD HH:MM:SSZ`. Haxeon's Date has no calendar fields. */
	public static function now():String {
		var seconds = Math.floor(Date.now().getTime() / 1000);
		var days = Math.floor(seconds / 86400), rest = seconds - days * 86400;
		// Civil date from days since 1970-01-01 (Howard Hinnant's days_from_civil, inverted).
		var z = days + 719468;
		var era = Math.floor(z / 146097);
		var dayOfEra = z - era * 146097;
		var yearOfEra = Math.floor((dayOfEra - Math.floor(dayOfEra / 1460) + Math.floor(dayOfEra / 36524) - Math.floor(dayOfEra / 146096)) / 365);
		var dayOfYear = dayOfEra - (365 * yearOfEra + Math.floor(yearOfEra / 4) - Math.floor(yearOfEra / 100));
		var monthIndex = Math.floor((5 * dayOfYear + 2) / 153);
		var day = dayOfYear - Math.floor((153 * monthIndex + 2) / 5) + 1;
		var month = monthIndex < 10 ? monthIndex + 3 : monthIndex - 9;
		var year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0);
		var two = function(value:Int):String {
			return StringTools.lpad(Std.string(value), "0", 2);
		};
		return year + "-" + two(month) + "-" + two(day) + " " + two(Math.floor(rest / 3600)) + ":" + two(Math.floor(rest / 60) % 60) + ":"
			+ two(rest % 60) + "Z";
	}
}
