package scm;

import haxe.io.Bytes;

class ScmBlob {
	public final bytes:Bytes;
	public final binary:Bool;

	public function new(bytes:Bytes, binary:Bool) {
		this.bytes = bytes.sub(0, bytes.length);
		this.binary = binary;
	}
}
