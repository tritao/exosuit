package workspace.runtime;

import haxe.io.Bytes;

/** Minimal secret-store boundary for relay bearer credentials. */
interface WorkspaceCredentialStore {
	function read(account:String):Null<Bytes>;
	function write(account:String, secret:Bytes):Void;
}
