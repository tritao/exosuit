package app;

typedef AgentLockHandle = hl.Abstract<"realtime_file_lock">;
typedef AgentProcessIdentityHandle = hl.Abstract<"realtime_process_identity">;

@:hlNative("haxeon_runtime", "__host_prepare_private_directory")
extern function nativePrepareDirectory(path:String):Bool;

@:hlNative("haxeon_runtime", "__host_check_private_directory")
extern function nativePrivateDirectory(path:String):Bool;

@:hlNative("haxeon_runtime", "__host_check_private_file")
extern function nativePrivateFile(path:String):Bool;

@:hlNative("haxeon_runtime", "__host_secure_random_token")
extern function nativeRandomToken():String;

@:hlNative("haxeon_runtime", "__host_choose_loopback_port")
extern function nativeChoosePort():Int;

@:hlNative("haxeon_runtime", "__host_file_lock_acquire")
extern function nativeAcquireLock(path:String):Null<AgentLockHandle>;

@:hlNative("haxeon_runtime", "__host_file_lock_release")
extern function nativeReleaseLock(lock:AgentLockHandle):Void;

@:hlNative("haxeon_runtime", "__host_file_lock_descriptor")
extern function nativeLockDescriptor(lock:AgentLockHandle):Int;

@:hlNative("haxeon_runtime", "__host_guard_inherited_file_lock")
extern function nativeGuardChildLock(environmentKey:String):Void;

@:hlNative("haxeon_runtime", "__host_set_private_umask")
extern function nativeSetPrivateUmask():Void;

@:hlNative("haxeon_runtime", "__host_install_stop_signals")
extern function nativeInstallStopSignals():Void;

@:hlNative("haxeon_runtime", "__host_stop_requested")
extern function nativeStopRequested():Bool;

@:hlNative("haxeon_runtime", "__host_regular_file_identity")
extern function nativeFileIdentity(path:String):Null<String>;

@:hlNative("haxeon_runtime", "__host_process_identity_open")
extern function nativeProcessOpen(pid:Int, expectedExecutable:String):Null<AgentProcessIdentityHandle>;

@:hlNative("haxeon_runtime", "__host_process_identity_terminate")
extern function nativeProcessTerminate(handle:AgentProcessIdentityHandle):Bool;

@:hlNative("haxeon_runtime", "__host_process_identity_close")
extern function nativeProcessClose(handle:AgentProcessIdentityHandle):Void;

/** Narrow host primitives used by the Haxe workspace manager. */
class AgentManagerNative {
	public static inline function prepareDirectory(path:String):Bool
		return nativePrepareDirectory(path);

	public static inline function privateDirectory(path:String):Bool
		return nativePrivateDirectory(path);

	public static inline function privateFile(path:String):Bool
		return nativePrivateFile(path);

	public static inline function randomToken():String
		return nativeRandomToken();

	public static inline function choosePort():Int
		return nativeChoosePort();

	public static inline function acquireLock(path:String):Null<AgentLockHandle>
		return nativeAcquireLock(path);

	public static inline function releaseLock(lock:AgentLockHandle):Void
		nativeReleaseLock(lock);

	public static inline function lockDescriptor(lock:AgentLockHandle):Int
		return nativeLockDescriptor(lock);

	public static inline function guardChildLock():Void
		nativeGuardChildLock("EXOSUIT_AGENT_LOCK_FD");

	public static inline function setPrivateUmask():Void
		nativeSetPrivateUmask();

	public static inline function installStopSignals():Void
		nativeInstallStopSignals();

	public static inline function stopRequested():Bool
		return nativeStopRequested();

	public static inline function fileIdentity(path:String):Null<String>
		return nativeFileIdentity(path);

	public static inline function openProcessIdentity(pid:Int, expectedExecutable:String):Null<AgentProcessIdentityHandle>
		return nativeProcessOpen(pid, expectedExecutable);

	public static inline function terminateProcess(handle:AgentProcessIdentityHandle):Bool
		return nativeProcessTerminate(handle);

	public static inline function closeProcessIdentity(handle:AgentProcessIdentityHandle):Void
		nativeProcessClose(handle);
}
