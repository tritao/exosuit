package textmateregex;

import haxe.io.Bytes;

/** One UTF-8 line and its UTF-8/UTF-16 boundary maps for repeated regex scans. */
class RegexInput {
	static inline final MAX_LINE_BYTES = 1024 * 1024;
	public final bytes:Bytes;
	final byteToUtf16:Null<Array<Int>>;
	final utf16ToByte:Null<Array<Int>>;

	public function new(text:String) {
		bytes = Bytes.ofString(text);
		if (bytes.length > MAX_LINE_BYTES) throw "TextMate input line exceeds 1 MiB";
		if (bytes.length == text.length) {
			byteToUtf16 = null;
			utf16ToByte = null;
			return;
		}
		byteToUtf16 = [0];
		utf16ToByte = [0];
		var byte = 0, utf16 = 0;
		while (byte < bytes.length) {
			var first = bytes.get(byte), width = first < 0x80 ? 1 : first < 0xe0 ? 2 : first < 0xf0 ? 3 : 4;
			if (byte + width > bytes.length) throw "Invalid UTF-8 input to Oniguruma";
			var scalar = width == 1 ? first : first & (width == 2 ? 0x1f : width == 3 ? 0x0f : 0x07);
			for (offset in 1...width) {
				var next = bytes.get(byte + offset);
				if ((next & 0xc0) != 0x80) throw "Invalid UTF-8 input to Oniguruma";
				scalar = (scalar << 6) | (next & 0x3f);
				byteToUtf16.push(utf16);
			}
			byte += width;
			var units = scalar > 0xffff ? 2 : 1;
			utf16 += units;
			byteToUtf16.push(utf16);
			if (units == 2) utf16ToByte.push(-1);
			utf16ToByte.push(byte);
		}
		if (utf16 != text.length) throw "Haxe string length disagrees with its UTF-8 encoding";
	}

	public function byteOffset(utf16Offset:Int):Int {
		if (utf16ToByte == null) {
			if (utf16Offset < 0 || utf16Offset > bytes.length) throw "TextMate regex start is outside the line";
			return utf16Offset;
		}
		if (utf16Offset < 0 || utf16Offset >= utf16ToByte.length) throw "TextMate regex start is outside the line";
		var result = utf16ToByte[utf16Offset];
		if (result < 0) throw "TextMate regex start splits a Unicode scalar";
		return result;
	}

	public function utf16Offset(byteOffset:Int):Int {
		if (byteToUtf16 == null) {
			if (byteOffset < 0 || byteOffset > bytes.length) throw "Oniguruma returned an offset outside the line";
			return byteOffset;
		}
		if (byteOffset < 0 || byteOffset >= byteToUtf16.length) throw "Oniguruma returned an offset outside the line";
		return byteToUtf16[byteOffset];
	}
}
