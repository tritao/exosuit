package devtools;

/**
	The HashLink GC's counters, for measuring memory use from outside (docs/benchmarks/memory). The window answers them
	to `exosuitctl call exosuit.memory`; a workspace service writes them to `<EXOSUIT_MEMORY_STATS>/service-<pid>.json`
	every few seconds when that variable names a folder. Nothing runs unless asked.
**/
class MemoryStats {
	/** The counters now; `collect` runs a full collection first, so the counters show what is retained. */
	public static function sample(collect:Bool = false):Dynamic {
		if (collect) hl.Gc.major();
		var stats = hl.Gc.stats();
		return {
			pid: Sys.getPid(),
			at: Sys.time(),
			heapBytes: hl.Gc.heapBytes(),
			allocatedBytes: hl.Gc.totalAllocated(),
			allocations: stats.allocationCount,
			collections: hl.Gc.collections(),
			markMicros: hl.Gc.markMicros()
		};
	}

	/**
		The allocation census over an interval: `start` begins it (one stack sample per 16 KiB allocated), `dump` stops
		it and writes it to `path` (read with haxeon/scripts/alloc-sites.py). Answers why it refused, or null: the path
		must be absolute and name no existing file, so a control call never writes relative to the window's folder or
		over a file.
	**/
	public static function census(action:String, path:Null<String>):Null<String> {
		switch action {
			case "start":
				hl.Gc.censusStart(16384);
				hl.Gc.censusReset();
			case "dump":
				if (path != null && !haxe.io.Path.isAbsolute(path)) return "census path must be absolute: " + path;
				if (path != null && sys.FileSystem.exists(path)) return "census path already exists: " + path;
				hl.Gc.censusStop();
				if (path != null) hl.Gc.censusDump(path);
			default:
				return "census is start or dump";
		}
		return null;
	}

	final directory:Null<String>;
	var next:Float = 0;

	/** A writer for the folder `EXOSUIT_MEMORY_STATS` names; a no-op without it. */
	public function new() {
		var named = Sys.getEnv("EXOSUIT_MEMORY_STATS");
		directory = named == null || named.length == 0 ? null : named;
	}

	/** Writes the counters once `period` seconds have passed since the last write; `force` writes now. */
	public function poll(now:Float, force:Bool = false, period:Float = 2.0):Void {
		var folder = directory;
		if (folder == null || (!force && now < next)) return;
		next = now + period;
		try {
			if (!sys.FileSystem.exists(folder)) sys.FileSystem.createDirectory(folder);
			var path = folder + "/service-" + Sys.getPid() + ".json";
			sys.io.File.saveContent(path + ".tmp", haxe.Json.stringify(sample()));
			sys.FileSystem.rename(path + ".tmp", path);
		} catch (_:Dynamic) {}
	}
}
