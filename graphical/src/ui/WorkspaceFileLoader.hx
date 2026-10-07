package ui;

/** Prioritized, bounded remote reads with revision-keyed recent-file caching. */
class WorkspaceFileLoader {
	public var capacity:Void->Int = function() return 2;
	public var active(default, null):Int = 0;
	public var cacheHits(default, null):Int = 0;
	public var completedReads(default, null):Int = 0;
	public var lastReadMs(default, null):Float = 0;
	public var cachedBytes(default, null):Int = 0;
	final jobs:Map<String, FileLoadJob> = [];
	final queue:Array<FileLoadJob> = [];
	final cache:Array<FileCacheEntry> = [];
	var epoch = 0;
	var pumping = false;

	public function new() {}

	public function clearCache():Void {
		epoch++;
		cache.resize(0);
		cachedBytes = 0;
	}

	public function load(key:String, revision:Null<String>,
			start:(WorkspaceFileReadResult->Void, Void->Bool)->Void,
			wanted:Void->Bool, complete:WorkspaceFileReadResult->Void):Void {
		if (revision != null) for (entry in cache.copy()) {
			if (entry.key != key || entry.result.revision != revision) continue;
			cache.remove(entry);
			cache.push(entry);
			cacheHits++;
			if (wanted()) complete(entry.result);
			return;
		}
		// Remove abandoned previews even while both network slots are occupied.
		for (queued in queue.copy()) if (!isWanted(queued)) {
			queue.remove(queued);
			jobs.remove(queued.id);
		}
		var jobKey = epoch + ":" + key.length + ":" + key + ":" +
			(revision == null ? "?" : revision.length + ":" + revision);
		var job = jobs.get(jobKey);
		if (job != null) {
			job.listeners.push({wanted: wanted, complete: complete});
			if (queue.remove(job)) queue.unshift(job);
		} else {
			job = {id: jobKey, key: key, epoch: epoch, start: start,
				listeners: [{wanted: wanted, complete: complete}]};
			jobs.set(jobKey, job);
			queue.unshift(job);
		}
		pump();
	}

	public function prioritize(key:String):Void {
		for (job in queue.copy()) if (job.key == key) {
			queue.remove(job);
			queue.unshift(job);
			break;
		}
		pump();
	}

	public function pump():Void {
		if (pumping) return;
		pumping = true;
		while (queue.length > 0 && active < capacity()) {
			var job = queue.shift();
			if (!isWanted(job)) { jobs.remove(job.id); continue; }
			active++;
			var started = Sys.time();
			job.start(function(result) {
				active--;
				jobs.remove(job.id);
				completedReads++;
				lastReadMs = (Sys.time() - started) * 1000;
				if (job.epoch == epoch && result.error == null && result.contents != null && result.revision != null)
					remember(job.key, result);
				for (listener in job.listeners) if (listener.wanted()) listener.complete(result);
				pump();
			}, function() return isWanted(job));
		}
		pumping = false;
	}

	static function isWanted(job:FileLoadJob):Bool {
		for (listener in job.listeners) if (listener.wanted()) return true;
		return false;
	}

	function remember(key:String, result:WorkspaceFileReadResult):Void {
		// Cache raw snapshots, not a second syntax/layout tree. Maximum 16 MiB / 16 files.
		for (entry in cache.copy()) if (entry.key == key) {
			cache.remove(entry);
			cachedBytes -= entry.result.sizeBytes;
		}
		cache.push({key: key, result: result});
		cachedBytes += result.sizeBytes;
		while (cache.length > 16 || cachedBytes > 16777216) cachedBytes -= cache.shift().result.sizeBytes;
	}
}

private typedef FileLoadJob = {
	var id:String;
	var key:String;
	var epoch:Int;
	var start:(WorkspaceFileReadResult->Void, Void->Bool)->Void;
	var listeners:Array<{wanted:Void->Bool, complete:WorkspaceFileReadResult->Void}>;
}
private typedef FileCacheEntry = {var key:String; var result:WorkspaceFileReadResult;}
