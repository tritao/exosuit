package app;

import sys.FileSystem;

/**
	A state folder's workspace.json, read again when it changes (Phase 5 changes a workspace's folders while its
	service runs). The file is parsed only when its size or time changed, or while it is young enough that a rewrite of
	the same size could share its time; a file that does not parse keeps the last good identity and is tried again on
	the next call.
**/
class AgentIdentityWatch {
	/** A file modified this recently is parsed on every call: the clock's granularity could hide a rewrite. */
	public static inline final YOUNG_SECONDS = 2;

	final path:String;
	final fallback:Void->AgentStateIdentity;
	final clock:Void->Float;
	var identity:AgentStateIdentity;
	var stamped:Null<String> = null;

	/** `fallback` is the identity of a state folder without the file. */
	public function new(path:String, fallback:Void->AgentStateIdentity, ?clock:Void->Float) {
		this.path = path;
		this.fallback = fallback;
		this.clock = clock == null ? Sys.time : clock;
		identity = load();
	}

	/** Stats, reads, stats again: a file that changed while it was read is looked at again on the next call. */
	function load():AgentStateIdentity {
		var before = stamp();
		var read = FileSystem.exists(path) ? AgentStateIdentity.read(path) : fallback();
		stamped = stamp() == before ? before : null;
		return read;
	}

	function stamp():String {
		var metadata = FileSystem.exists(path) ? FileSystem.metadata(path) : null;
		return metadata == null ? "" : metadata.size + ":" + metadata.modified;
	}

	/** The latest good identity. */
	public function current():AgentStateIdentity {
		var now = stamp();
		var young = false;
		if (now != "") {
			var metadata = FileSystem.metadata(path);
			young = metadata != null && clock() - metadata.modified < YOUNG_SECONDS;
		}
		if (now == stamped && !young) return identity;
		try {
			identity = load();
		} catch (_:Dynamic) {
			// A torn or garbage file: keep what we had, and look again next time.
			stamped = null;
		}
		return identity;
	}
}
