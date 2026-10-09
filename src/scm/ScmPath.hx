package scm;

import haxe.io.Bytes;

/** Lossless Git path bytes with a single-line, safe label for UI surfaces. */
class ScmPath {
	public static function display(bytes:Bytes):String {
		var result = new StringBuf(), index = 0;
		while (index < bytes.length) {
			var first = bytes.get(index), width = utf8Width(bytes, index);
			if (first == 0x5c) {
				result.add("\\\\");
				index++;
			} else if (first == 0x0a) {
				result.add("\\n");
				index++;
			} else if (first == 0x0d) {
				result.add("\\r");
				index++;
			} else if (first == 0x09) {
				result.add("\\t");
				index++;
			} else if (first >= 0x20 && first < 0x7f) {
				result.addChar(first);
				index++;
			} else if (width > 0) {
				result.add(bytes.getString(index, width));
				index += width;
			} else {
				result.add("\\x");
				result.add(hex(first));
				index++;
			}
		}
		return result.toString();
	}

	static function utf8Width(bytes:Bytes, index:Int):Int {
		var first = bytes.get(index), width = first >= 0xc2 && first <= 0xdf ? 2
			: first >= 0xe0 && first <= 0xef ? 3 : first >= 0xf0 && first <= 0xf4 ? 4 : 0;
		if (width == 0 || index + width > bytes.length) return 0;
		for (offset in 1...width) {
			var next = bytes.get(index + offset);
			if ((next & 0xc0) != 0x80) return 0;
			if (offset == 1 && ((first == 0xe0 && next < 0xa0) || (first == 0xed && next >= 0xa0)
				|| (first == 0xf0 && next < 0x90) || (first == 0xf4 && next >= 0x90))) return 0;
		}
		return width;
	}

	static function hex(value:Int):String {
		var digits = "0123456789abcdef";
		return digits.charAt((value >> 4) & 15) + digits.charAt(value & 15);
	}
}
