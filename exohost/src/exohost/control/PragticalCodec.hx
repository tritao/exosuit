package exohost.control;

import haxe.io.Bytes;
import haxe.io.BytesBuffer;

/**
	Pragtical control protocol v1 on the wire (docs/design/exosuitctl/TDD-exosuit-ctl.md §2.6, §11): a frame is a 4-byte
	big-endian length and one MessagePack value, at most 16 MiB. Only Pragtical's subset is read and written: nil,
	booleans, integers within ±2^53, strings, arrays and maps with string keys, at most 32 deep; floats, bin and ext are
	refused, and so are trailing bytes. Values are plain Haxe values (objects for maps) so they pass to and from JSON.
**/
class PragticalCodec {
	public static inline final MAX_FRAME = 16 * 1024 * 1024;
	static inline final MAX_DEPTH = 32;
	static inline final SAFE = 9007199254740991.0;

	/** One frame: the length, then the encoded value. */
	public static function frame(value:Dynamic):Bytes {
		var body = encode(value);
		var out = Bytes.alloc(4 + body.length);
		out.set(0, (body.length >>> 24) & 0xff);
		out.set(1, (body.length >>> 16) & 0xff);
		out.set(2, (body.length >>> 8) & 0xff);
		out.set(3, body.length & 0xff);
		out.blit(4, body, 0, body.length);
		return out;
	}

	/** The length a frame starting at `offset` declares; throws when it exceeds the limit. */
	public static function frameLength(buffer:Bytes, offset:Int):Int {
		var length = (buffer.get(offset) << 24) | (buffer.get(offset + 1) << 16) | (buffer.get(offset + 2) << 8) | buffer.get(offset + 3);
		if (length < 0 || length > MAX_FRAME)
			throw "frame too large";
		return length;
	}

	public static function encode(value:Dynamic):Bytes {
		var out = new BytesBuffer();
		write(out, value, 0);
		return out.getBytes();
	}

	public static function decode(bytes:Bytes):Dynamic {
		var reader = new Reader(bytes);
		var value = reader.value(0);
		if (reader.position != bytes.length)
			throw "trailing bytes after the value";
		return value;
	}

	static function write(out:BytesBuffer, value:Dynamic, depth:Int):Void {
		if (depth > MAX_DEPTH)
			throw "value nested too deep";
		if (value == null) {
			out.addByte(0xc0);
		} else if (Std.isOfType(value, Bool)) {
			out.addByte(value ? 0xc3 : 0xc2);
		} else if (Std.isOfType(value, Int)) {
			writeInteger(out, (value : Int));
		} else if (Std.isOfType(value, Float)) {
			// The subset has no floats: whole numbers go as integers, anything else is cut to one.
			var number:Float = value;
			if (!Math.isFinite(number) || Math.abs(number) > SAFE)
				throw "number outside ±2^53";
			writeWhole(out, number < 0 ? Math.fceil(number) : Math.ffloor(number));
		} else if (Std.isOfType(value, String)) {
			var bytes = Bytes.ofString(value);
			var length = bytes.length;
			if (length < 32)
				out.addByte(0xa0 | length);
			else if (length < 0x100) {
				out.addByte(0xd9);
				out.addByte(length);
			} else if (length < 0x10000) {
				out.addByte(0xda);
				addUInt16(out, length);
			} else {
				out.addByte(0xdb);
				addUInt32(out, length);
			}
			out.add(bytes);
		} else if (Std.isOfType(value, Array)) {
			var items:Array<Dynamic> = value;
			header(out, items.length, 0x90, 0xdc, 0xdd);
			for (item in items)
				write(out, item, depth + 1);
		} else if (Reflect.isObject(value)) {
			var fields = Reflect.fields(value);
			header(out, fields.length, 0x80, 0xde, 0xdf);
			for (field in fields) {
				write(out, field, depth + 1);
				write(out, Reflect.field(value, field), depth + 1);
			}
		} else
			throw "cannot encode " + Std.string(value);
	}

	static function header(out:BytesBuffer, count:Int, fixed:Int, small:Int, large:Int):Void {
		if (count < 16)
			out.addByte(fixed | count);
		else if (count < 0x10000) {
			out.addByte(small);
			addUInt16(out, count);
		} else {
			out.addByte(large);
			addUInt32(out, count);
		}
	}

	static function writeInteger(out:BytesBuffer, value:Int):Void {
		if (value >= 0 && value < 128)
			out.addByte(value);
		else if (value < 0 && value >= -32)
			out.addByte(value & 0xff);
		else if (value >= 0 && value < 0x100) {
			out.addByte(0xcc);
			out.addByte(value);
		} else if (value >= 0 && value < 0x10000) {
			out.addByte(0xcd);
			addUInt16(out, value);
		} else if (value >= 0) {
			out.addByte(0xce);
			addUInt32(out, value);
		} else if (value >= -128) {
			out.addByte(0xd0);
			out.addByte(value & 0xff);
		} else if (value >= -32768) {
			out.addByte(0xd1);
			addUInt16(out, value & 0xffff);
		} else {
			out.addByte(0xd2);
			addUInt32(out, value);
		}
	}

	/** A whole number that may not fit 32 bits (a time in milliseconds). */
	static function writeWhole(out:BytesBuffer, value:Float):Void {
		if (value >= -2147483648.0 && value <= 2147483647.0) {
			writeInteger(out, Std.int(value));
			return;
		}
		// Two's complement halves: the high word is the floor of value / 2^32, the low word what remains (0 to 2^32 - 1).
		var high = Math.ffloor(value / 4294967296.0), low = value - high * 4294967296.0;
		out.addByte(value >= 0 ? 0xcf : 0xd3);
		addUInt32(out, Std.int(high));
		addUInt32(out, low >= 2147483648.0 ? Std.int(low - 4294967296.0) : Std.int(low));
	}

	static function addUInt16(out:BytesBuffer, value:Int):Void {
		out.addByte((value >>> 8) & 0xff);
		out.addByte(value & 0xff);
	}

	static function addUInt32(out:BytesBuffer, value:Int):Void {
		out.addByte((value >>> 24) & 0xff);
		out.addByte((value >>> 16) & 0xff);
		out.addByte((value >>> 8) & 0xff);
		out.addByte(value & 0xff);
	}
}

private class Reader {
	final bytes:Bytes;
	public var position(default, null):Int = 0;

	public function new(bytes:Bytes)
		this.bytes = bytes;

	public function value(depth:Int):Dynamic {
		if (depth > 32)
			throw "value nested too deep";
		var marker = byte();
		if (marker < 0x80)
			return marker;
		if (marker >= 0xe0)
			return marker - 0x100;
		if (marker & 0xf0 == 0x80)
			return map(marker & 0x0f, depth);
		if (marker & 0xf0 == 0x90)
			return array(marker & 0x0f, depth);
		if (marker & 0xe0 == 0xa0)
			return string(marker & 0x1f);
		return switch marker {
			case 0xc0: null;
			case 0xc2: false;
			case 0xc3: true;
			case 0xcc: byte();
			case 0xcd: uint(2);
			case 0xce: whole(0, uint(4));
			case 0xcf: whole(uint(4), uint(4));
			case 0xd0: signed(byte(), 8);
			case 0xd1: signed(uint(2), 16);
			case 0xd2: uint(4);
			case 0xd3:
				var high = uint(4), low = uint(4);
				var number = (high : Float) * 4294967296.0 + (low < 0 ? (low : Float) + 4294967296.0 : (low : Float));
				if (Math.abs(number) > 9007199254740991.0)
					throw "integer outside ±2^53";
				number >= -2147483648.0 && number <= 2147483647.0 ? Std.int(number) : number;
			case 0xd9: string(byte());
			case 0xda: string(uint(2));
			case 0xdb: string(uint(4));
			case 0xdc: array(uint(2), depth);
			case 0xdd: array(uint(4), depth);
			case 0xde: map(uint(2), depth);
			case 0xdf: map(uint(4), depth);
			case 0xca | 0xcb: throw "floats are not part of the protocol";
			default: throw "bin and ext are not part of the protocol";
		}
	}

	function map(count:Int, depth:Int):Dynamic {
		var result:Dynamic = {};
		for (_ in 0...count) {
			var key = value(depth + 1);
			if (!Std.isOfType(key, String))
				throw "map keys must be strings";
			Reflect.setField(result, key, value(depth + 1));
		}
		return result;
	}

	function array(count:Int, depth:Int):Array<Dynamic> {
		if (count > bytes.length - position)
			throw "truncated array";
		return [for (_ in 0...count) value(depth + 1)];
	}

	function string(length:Int):String {
		need(length);
		var text = bytes.getString(position, length);
		position += length;
		return text;
	}

	/** An unsigned 64-bit value from its two halves, as an Int when it fits, else a Float within 2^53. */
	static function whole(high:Int, low:Int):Dynamic {
		var number = (high : Float) * 4294967296.0 + (low < 0 ? (low : Float) + 4294967296.0 : (low : Float));
		if (high < 0 || number > 9007199254740991.0)
			throw "integer outside ±2^53";
		return number <= 2147483647.0 ? Std.int(number) : number;
	}

	static function signed(value:Int, bits:Int):Int
		return value >= 1 << (bits - 1) ? value - (1 << bits) : value;

	function byte():Int {
		need(1);
		return bytes.get(position++);
	}

	function uint(count:Int):Int {
		need(count);
		var result = 0;
		for (_ in 0...count)
			result = (result << 8) | bytes.get(position++);
		return result;
	}

	function need(count:Int):Void
		if (count < 0 || position + count > bytes.length)
			throw "truncated value";
}
