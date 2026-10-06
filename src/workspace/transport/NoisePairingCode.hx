package workspace.transport;

import haxe.io.Bytes;

/** Human-comparable six-digit code derived from the completed Noise transcript. */
class NoisePairingCode {
	public static function fromHandshakeHash(hash:Bytes):String {
		if (hash == null || hash.length != 32)
			throw "Invalid Noise pairing transcript hash";
		var value:Float = 0;
		for (index in 0...4)
			value = value * 256 + hash.get(index);
		var digits = StringTools.lpad(Std.string(Std.int(value % 1000000)), "0", 6);
		return digits.substr(0, 3) + " " + digits.substr(3, 3);
	}
}
