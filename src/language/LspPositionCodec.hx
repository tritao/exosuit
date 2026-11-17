package language;

import editor.BufferPosition;
import editor.TextBuffer;

/** LSP positions negotiated as UTF-16 code units, matching TextBuffer columns. */
class LspPositionCodec {
	public static function encode(position:BufferPosition):Dynamic
		return {line: position.line, character: position.column};

	public static function decode(buffer:TextBuffer, value:Dynamic):Null<BufferPosition> {
		if (value == null) return null;
		var line = dynamicInt(Reflect.field(value, "line")), column = dynamicInt(Reflect.field(value, "character"));
		if (line < 0 || line >= buffer.lineCount() || column < 0 || column > buffer.line(line).length) return null;
		var position = buffer.positionAt(line, column);
		return position.line == line && position.column == column ? position : null;
	}

	public static function advance(start:BufferPosition, text:String):BufferPosition {
		var lines = text.split("\n");
		return lines.length == 1 ? new BufferPosition(start.line, start.column + text.length) :
			new BufferPosition(start.line + lines.length - 1, lines[lines.length - 1].length);
	}

	static function dynamicInt(value:Dynamic):Int
		return value == null ? -1 : Std.parseInt(Std.string(value)) ?? 0;
}
