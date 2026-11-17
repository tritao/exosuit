package app;

typedef AgentLockHandle = hl.Abstract<"realtime_file_lock">;
typedef AgentProcessIdentityHandle = hl.Abstract<"realtime_process_identity">;

@:hlNative("haxeon_runtime", "__host_prepare_private_directory")
extern function nativePrepareDirectory(path:String):Bool;

@:hlNative("haxeon_runtime", "__host_check_private_file")
extern function nativePrivateFile(path:String):Bool;

@:hlNative("haxeon_runtime", "__host_secure_random_token")
extern function nativeRandomToken():String;

@:hlNative("haxeon_runtime", "__host_file_lock_acquire")
extern function nativeAcquireLock(path:String):Null<AgentLockHandle>;

@:hlNative("haxeon_runtime", "__host_file_lock_release")
extern function nativeReleaseLock(lock:AgentLockHandle):Void;

@:hlNative("haxeon_runtime", "__host_set_private_umask")
extern function nativeSetPrivateUmask():Void;

@:hlNative("haxeon_runtime", "__host_install_stop_signals")
extern function nativeInstallStopSignals():Void;

@:hlNative("haxeon_runtime", "__host_stop_requested")
extern function nativeStopRequested():Bool;

@:hlNative("haxeon_runtime", "__host_process_identity_open")
extern function nativeProcessOpen(pid:Int, expectedExecutable:String):Null<AgentProcessIdentityHandle>;

@:hlNative("haxeon_runtime", "__host_process_alive")
extern function nativeProcessAlive(pid:Int, expectedExecutable:Null<String>):Bool;

@:hlNative("haxeon_runtime", "__host_process_identity_terminate")
extern function nativeProcessTerminate(handle:AgentProcessIdentityHandle):Bool;

@:hlNative("haxeon_runtime", "__host_process_identity_close")
extern function nativeProcessClose(handle:AgentProcessIdentityHandle):Void;

/** Narrow host primitives the workspace service and its terminal hosts use. */
class AgentNative {
	/** True while the process runs; with an executable, only if that is its image (a reused id is another process). */
	public static inline function processAlive(pid:Int, ?expectedExecutable:String):Bool
		return nativeProcessAlive(pid, expectedExecutable);

	public static inline function prepareDirectory(path:String):Bool
		return nativePrepareDirectory(path);

	public static inline function privateFile(path:String):Bool
		return nativePrivateFile(path);

	public static inline function randomToken():String
		return nativeRandomToken();

	public static inline function acquireLock(path:String):Null<AgentLockHandle>
		return nativeAcquireLock(path);

	public static inline function releaseLock(lock:AgentLockHandle):Void
		nativeReleaseLock(lock);

	public static inline function setPrivateUmask():Void
		nativeSetPrivateUmask();

	public static inline function installStopSignals():Void
		nativeInstallStopSignals();

	public static inline function stopRequested():Bool
		return nativeStopRequested();

	public static inline function openProcessIdentity(pid:Int, expectedExecutable:String):Null<AgentProcessIdentityHandle>
		return nativeProcessOpen(pid, expectedExecutable);

	public static inline function terminateProcess(handle:AgentProcessIdentityHandle):Bool
		return nativeProcessTerminate(handle);

	public static inline function closeProcessIdentity(handle:AgentProcessIdentityHandle):Void
		nativeProcessClose(handle);
}
