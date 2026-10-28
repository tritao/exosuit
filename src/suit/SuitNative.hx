package suit;

typedef SuitLockHandle = hl.Abstract<"realtime_file_lock">;

@:hlNative("haxeon_runtime", "__host_prepare_private_directory")
extern function nativePrepareDirectory(path:String):Bool;

@:hlNative("haxeon_runtime", "__host_file_lock_acquire")
extern function nativeAcquireLock(path:String):Null<SuitLockHandle>;

@:hlNative("haxeon_runtime", "__host_file_lock_release")
extern function nativeReleaseLock(lock:SuitLockHandle):Void;

/** Host primitives from the Haxeon runtime, which every exosuit HashLink program loads. */
class SuitNative {
	/** Creates `path` readable only by this user, or checks that an existing one is. */
	public static function prepareDirectory(path:String):Bool
		return nativePrepareDirectory(path);

	/** The single-instance lock: the exclusive file lock the workspace manager also uses. Null when held. */
	public static function acquireLock(path:String):Null<SuitLockHandle>
		return nativeAcquireLock(path);

	public static function releaseLock(lock:SuitLockHandle):Void
		nativeReleaseLock(lock);
}
