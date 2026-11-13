package workspace.runtime;

/**
	Dated lines saying why a service or one of its terminals started or ended. The daemon's standard output is copied
	into the workspace's `manager.log` by its manager, so the lines survive the service and can be counted later.
**/
class ServiceLog {
	public static function line(message:String):String
		return "[" + now() + "] " + message;

	/** Never throws: the manager at the other end of the pipe may be gone. */
	public static function note(message:String):Void {
		try {
			Sys.println(line(message));
			Sys.stdout().flush();
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
