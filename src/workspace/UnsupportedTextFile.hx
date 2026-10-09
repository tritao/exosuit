package workspace;

import haxe.io.Bytes;

/** A file-format result, not a runtime error. Retains only a bounded hex preview. */
class UnsupportedTextFile {
	public static inline final PreviewLimit:Int = 4096;
	public final path:String;
	public final sizeBytes:Int;
	public final binary:Bool;
	public final previewBytes:Int;
	public final bytePreview:String;

	public function new(path:String, bytes:Bytes, binary:Bool) {
		this.path = path;
		this.sizeBytes = bytes.length;
		this.binary = binary;
		this.previewBytes = Std.int(Math.min(bytes.length, PreviewLimit));
		var output = new StringBuf();
		var offset = 0;
		while (offset < previewBytes) {
			output.add(StringTools.hex(offset, 8)); output.add("  ");
			var end = Std.int(Math.min(offset + 16, previewBytes));
			for (index in offset...end) { output.add(StringTools.hex(bytes.get(index), 2)); output.add(" "); }
			output.add("\n"); offset = end;
		}
		bytePreview = output.toString();
	}

	public function toString():String
		return binary ? "This file contains binary data." : "This file uses an unsupported text encoding.";
}
