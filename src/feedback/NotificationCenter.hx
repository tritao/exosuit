package feedback;

class NotificationCenter {
	public static inline final DISPLAY_SECONDS = 6.0;
	public final capacity:Int;
	public final entries:Array<Notification> = [];
	public var revision(default, null):Int = 0;
	var nextId:Int = 1;
	var dismissedToast:Int = 0;

	public function new(capacity:Int = 100) {
		if (capacity < 1) throw "notification capacity must be positive";
		this.capacity = capacity;
	}

	public function publish(message:String, kind:NotificationKind = Information, source:String = "", ?actions:Array<NotificationAction>):Notification {
		var entry = new Notification(message, kind, Sys.time(), nextId++, source, actions);
		entries.push(entry);
		while (entries.length > capacity) entries.shift();
		revision++;
		return entry;
	}

	public function current(?now:Float):Null<Notification> {
		if (entries.length == 0) return null;
		var entry = entries[entries.length - 1], currentTime = now == null ? Sys.time() : now;
		return entry.id != dismissedToast && currentTime - entry.createdAt <= DISPLAY_SECONDS ? entry : null;
	}

	public function unreadCount():Int {
		var count = 0;
		for (entry in entries) if (!entry.read) count++;
		return count;
	}

	public function history():Array<Notification> {
		var result = entries.copy();
		result.reverse();
		return result;
	}

	public function markRead(id:Int):Void {
		for (entry in entries) if (entry.id == id && !entry.read) { entry.markRead(); revision++; return; }
	}

	public function markAllRead():Void {
		if (unreadCount() == 0) return;
		for (entry in entries) entry.markRead();
		revision++;
	}

	/** Hiding a transient message leaves its unread history intact. */
	public function dismissToast():Void {
		var entry = current();
		if (entry != null) { dismissedToast = entry.id; revision++; }
	}

	public function dismiss(id:Int):Void {
		for (entry in entries) if (entry.id == id) { entries.remove(entry); revision++; return; }
	}

	public function clear():Void {
		if (entries.length == 0) return;
		entries.resize(0);
		revision++;
	}
}
