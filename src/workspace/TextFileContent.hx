package workspace;

import haxe.io.Bytes;

/** Validate bytes before the runtime converts them to a text string. */
class TextFileContent {
	public static function decode(bytes:Bytes, path:String):String {
		for (index in 0...bytes.length) if (bytes.get(index) == 0)
			throw new UnsupportedTextFile(path, bytes, true);
		if (!validUtf8(bytes)) throw new UnsupportedTextFile(path, bytes, false);
		return bytes.toString();
	}

	public static function validUtf8(bytes:Bytes):Bool {
		var index = 0;
		while (index < bytes.length) {
			var first = bytes.get(index++);
			if (first <= 0x7f) continue;
			var continuation:Int;
			var secondMin = 0x80, secondMax = 0xbf;
			if (first >= 0xc2 && first <= 0xdf) continuation = 1;
			else if (first == 0xe0) { continuation = 2; secondMin = 0xa0; }
			else if (first >= 0xe1 && first <= 0xec || first >= 0xee && first <= 0xef) continuation = 2;
			else if (first == 0xed) { continuation = 2; secondMax = 0x9f; }
			else if (first == 0xf0) { continuation = 3; secondMin = 0x90; }
			else if (first >= 0xf1 && first <= 0xf3) continuation = 3;
			else if (first == 0xf4) { continuation = 3; secondMax = 0x8f; }
			else return false;
			if (index + continuation > bytes.length) return false;
			var second = bytes.get(index++);
			if (second < secondMin || second > secondMax) return false;
			for (_ in 1...continuation) {
				var next = bytes.get(index++);
				if (next < 0x80 || next > 0xbf) return false;
			}
		}
		return true;
	}
}
