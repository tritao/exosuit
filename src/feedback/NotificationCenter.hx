package feedback;

class NotificationCenter {
	public static inline final DISPLAY_SECONDS = 6.0;
	public final capacity:Int;
	public final entries:Array<Notification> = [];

	public function new(capacity:Int = 100) {
		if (capacity < 1) throw "notification capacity must be positive";
		this.capacity = capacity;
	}

	public function publish(message:String, kind:NotificationKind = Information):Notification {
		var entry = new Notification(message, kind, Sys.time());
		entries.push(entry);
		while (entries.length > capacity) entries.shift();
		return entry;
	}

	public function current(?now:Float):Null<Notification> {
		if (entries.length == 0) return null;
		var entry = entries[entries.length - 1], currentTime = now == null ? Sys.time() : now;
		return currentTime - entry.createdAt <= DISPLAY_SECONDS ? entry : null;
	}

	public function clear():Void
		entries.resize(0);
}
