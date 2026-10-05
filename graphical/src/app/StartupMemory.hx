package app;

import haxe.Json;
import haxe.io.Bytes;
import sys.FileSystem;
import sys.io.File;

/** Opt-in startup observations; no work is performed during ordinary launches. */
class StartupMemory {
	public static function sample(directory:String, stage:String):Void {
		if (!FileSystem.exists(directory)) FileSystem.createDirectory(directory);
		var counters = {
			stage: stage,
			gcHeapCapacityBytes: hl.Gc.heapBytes(),
			gcCumulativeAllocatedBytes: hl.Gc.totalAllocated(),
			gcAllocatedSinceCollectionBytes: hl.Gc.allocatedSinceCollection(),
			gcCollections: hl.Gc.collections(),
			gcMarkMicros: hl.Gc.markMicros()
		};
		File.saveContent(directory + "/" + stage + ".json", Json.stringify(counters));
		if (Sys.systemName() == "Linux") {
			Sys.command("cp", ["/proc/" + Sys.getPid() + "/smaps", directory + "/" + stage + ".smaps"]);
			Sys.command("cp", ["/proc/" + Sys.getPid() + "/smaps_rollup", directory + "/" + stage + ".rollup"]);
		}
		// End the profile before teardown frees startup allocations.
		if (Sys.getEnv("EXOSUIT_STARTUP_MEMORY_STOP_AT") == stage) Sys.exit(0);
	}
	public static function dump(directory:String):Void {
		var path = Bytes.ofString(directory + "/startup.heap");
		var terminated = Bytes.alloc(path.length + 1);
		terminated.blit(0, path, 0, path.length);
		hl.Gc.dump(StartupMemoryBytes.data(terminated));
	}
}

private extern class StartupMemoryBytes {
	@:hlNative("haxeon_runtime", "__bytes_get_data")
	public static function data(value:Bytes):hl.Bytes;
}
