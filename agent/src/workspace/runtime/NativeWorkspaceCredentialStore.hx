package workspace.runtime;

import haxe.io.Bytes;
import haxeon.credentials.Credentials;

/** NativeKit-backed storage scoped to this application and the current OS user. */
class NativeWorkspaceCredentialStore implements WorkspaceCredentialStore {
	static inline final SERVICE:String = "com.exosuit.workspace-relay";

	public function new() {}

	public function read(account:String):Null<Bytes>
		return Credentials.get(SERVICE, account);

	public function write(account:String, secret:Bytes):Void
		Credentials.set(SERVICE, account, secret);
}
