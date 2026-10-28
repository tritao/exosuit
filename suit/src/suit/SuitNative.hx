package suit;

typedef SuitLockHandle = hl.Abstract<"realtime_file_lock">;

@:hlNative("haxeon_runtime", "__host_file_lock_acquire")
extern function nativeAcquireLock(path:String):Null<SuitLockHandle>;

@:hlNative("haxeon_runtime", "__host_file_lock_release")
extern function nativeReleaseLock(lock:SuitLockHandle):Void;

/** The single-instance lock: the same exclusive file lock the workspace manager uses for its state. */
class SuitNative {
	public static function acquireLock(path:String):Null<SuitLockHandle>
		return nativeAcquireLock(path);

	public static function releaseLock(lock:SuitLockHandle):Void
		nativeReleaseLock(lock);
}
