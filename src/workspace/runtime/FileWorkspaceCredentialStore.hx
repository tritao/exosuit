package workspace.runtime;

import haxe.crypto.Sha256;
import haxe.io.Bytes;
import haxe.io.Path;
import sys.FileSystem;

/**
	Test-only secret store: one hex file per account in a directory the test owns. It exists so local
	relay tests never write to the user's OS credential store; `WorkspaceCredentialStores` hands it out
	only for loopback development relays.
**/
class FileWorkspaceCredentialStore implements WorkspaceCredentialStore {
	final directory:String;

	public function new(directory:String) {
		if (directory == null || directory.length == 0 || !FileSystem.isDirectory(directory))
			throw "Test credential directory does not exist";
		this.directory = directory;
	}

	public function read(account:String):Null<Bytes> {
		var path = pathFor(account);
		if (!FileSystem.exists(path))
			return null;
		var text = StringTools.trim(sys.io.File.getContent(path));
		return text.length == 0 ? null : fromHex(text);
	}

	public function write(account:String, secret:Bytes):Void {
		if (secret == null || secret.length == 0)
			throw "credential secret must contain at least one byte";
		sys.io.AtomicFile.write(pathFor(account), toHex(secret) +"\n");
	}

	function pathFor(account:String):String
		return Path.join([directory, Sha256.encode("com.exosuit.workspace-relay\n" + account).substr(0, 32) + ".secret"]);

	static function toHex(bytes:Bytes):String {
		var digits = "0123456789abcdef";
		var out = new StringBuf();
		for (index in 0...bytes.length) {
			out.addChar(digits.charCodeAt(bytes.get(index) >> 4));
			out.addChar(digits.charCodeAt(bytes.get(index) & 15));
		}
		return out.toString();
	}

	static function fromHex(text:String):Bytes {
		if (text.length % 2 != 0)
			throw "Invalid test credential file";
		var bytes = Bytes.alloc(text.length >> 1);
		for (index in 0...bytes.length) {
			var high = digit(text.charCodeAt(index * 2)), low = digit(text.charCodeAt(index * 2 + 1));
			if (high < 0 || low < 0)
				throw "Invalid test credential file";
			bytes.set(index, high * 16 + low);
		}
		return bytes;
	}

	static function digit(code:Null<Int>):Int {
		if (code == null)
			return -1;
		if (code >= 48 && code <= 57)
			return code - 48;
		if (code >= 97 && code <= 102)
			return code - 87;
		return -1;
	}
}
