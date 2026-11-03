package session;

import core.Application;

/**
	Debounces session snapshots and supports an explicit shutdown flush. session.conf holds the window chrome and the
	focused context; every context's tabs go to its own file in `store`: right after the window switches context
	(the context it left is written then), every `CONTEXT_PERIOD_SECONDS` while anything changed, and on `flush`.
**/
class SessionPersistence {
	public static inline final CHECK_INTERVAL_SECONDS = 0.25;
	public static inline final DEBOUNCE_SECONDS = 0.75;
	public static inline final CONTEXT_PERIOD_SECONDS = 30.0;
	final path:String;
	final store:Null<ContextSnapshotStore>;
	var lastChecked:Float = -1.0;
	var changedAt:Float = -1.0;
	var observed:String = "";
	var saved:String = "";
	var activeKey:String = "";
	var lastContextSync:Float = -1.0;

	public function new(path:String, ?store:ContextSnapshotStore) {
		this.path = path;
		this.store = store;
	}

	public function begin(application:Application, ?now:Float):Void {
		var session = WorkspaceSession.capture(application);
		observed = session.encode();
		saved = observed;
		changedAt = -1.0;
		activeKey = session.activeKey;
		lastContextSync = now == null ? Sys.time() : now;
		// Writes what the files lack (contexts migrated from an old session.conf) and nothing else, off this turn.
		if (store != null) store.request(session.contexts);
	}

	public function update(application:Application, now:Float):Bool {
		if (lastChecked >= 0 && now - lastChecked < CHECK_INTERVAL_SECONDS) return false;
		lastChecked = now;
		if (store != null) store.pump();
		var session = WorkspaceSession.capture(application);
		var current = session.encode();
		if (store != null && (session.activeKey != activeKey || now - lastContextSync >= CONTEXT_PERIOD_SECONDS)) {
			activeKey = session.activeKey;
			lastContextSync = now;
			store.request(session.contexts);
		}
		if (current != observed) {
			observed = current;
			changedAt = now;
			return false;
		}
		if (changedAt < 0 || now - changedAt < DEBOUNCE_SECONDS || current == saved) return false;
		if (!session.save(path)) return false;
		saved = current;
		changedAt = -1.0;
		return true;
	}

	public function flush(application:Application):Bool {
		var session = WorkspaceSession.capture(application), current = session.encode();
		if (store != null) store.sync(session.contexts);
		if (current == saved) return true;
		if (!session.save(path)) return false;
		observed = current;
		saved = current;
		changedAt = -1.0;
		return true;
	}
}
