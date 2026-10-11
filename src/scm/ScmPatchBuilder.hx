package scm;

import haxe.io.Bytes;

/** Builds a file-scoped unified patch for one LineDiff hunk. */
class ScmPatchBuilder {
	public static function build(path:Bytes, oldText:String, newText:String, hunks:Array<LineDiffHunk>, index:Int):Null<Bytes> {
		if (path == null || path.length == 0 || hunks == null || index < 0 || index >= hunks.length) return null;
		var oldLines = LineDiff.splitLines(oldText == null ? "" : oldText), newLines = LineDiff.splitLines(newText == null ? "" : newText);
		var hunk = hunks[index];
		var contextBefore = Std.int(Math.min(3, Math.min(hunk.oldStart, hunk.newStart)));
		if (index > 0) {
			var previous = hunks[index - 1];
			contextBefore = Std.int(Math.min(contextBefore, Math.min(
				hunk.oldStart - (previous.oldStart + previous.oldCount),
				hunk.newStart - (previous.newStart + previous.newCount))));
		}
		if (contextBefore < 0) return null;
		var oldAfter = hunk.oldStart + hunk.oldCount, newAfter = hunk.newStart + hunk.newCount;
		var contextAfter = Std.int(Math.min(3, Math.min(oldLines.length - oldAfter, newLines.length - newAfter)));
		if (index + 1 < hunks.length) {
			var next = hunks[index + 1];
			contextAfter = Std.int(Math.min(contextAfter, Math.min(next.oldStart - oldAfter, next.newStart - newAfter)));
		}
		if (contextAfter < 0 || hunk.oldStart < 0 || hunk.newStart < 0 ||
			hunk.oldStart + hunk.oldCount > oldLines.length || hunk.newStart + hunk.newCount > newLines.length) return null;

		var oldStart = hunk.oldStart - contextBefore, newStart = hunk.newStart - contextBefore;
		var oldCount = contextBefore + hunk.oldCount + contextAfter, newCount = contextBefore + hunk.newCount + contextAfter;
		var pathA = quotePath("a/", path), pathB = quotePath("b/", path);
		var out = new StringBuf();
		out.add("diff --git " + pathA + " " + pathB + "\n");
		if (oldLines.length == 0) out.add("new file mode 100644\n");
		else if (newLines.length == 0) out.add("deleted file mode 100644\n");
		out.add("--- " + (oldLines.length == 0 ? "/dev/null" : pathA) + "\n");
		out.add("+++ " + (newLines.length == 0 ? "/dev/null" : pathB) + "\n");
		out.add("@@ -" + range(oldStart, oldCount) + " +" + range(newStart, newCount) + " @@\n");
		for (line in oldStart...hunk.oldStart) addLine(out, " ", oldLines[line]);
		for (line in hunk.oldStart...(hunk.oldStart + hunk.oldCount)) addLine(out, "-", oldLines[line]);
		for (line in hunk.newStart...(hunk.newStart + hunk.newCount)) addLine(out, "+", newLines[line]);
		for (line in oldAfter...(oldAfter + contextAfter)) addLine(out, " ", oldLines[line]);
		return Bytes.ofString(out.toString());
	}

	static function addLine(out:StringBuf, prefix:String, line:String):Void {
		var terminated = StringTools.endsWith(line, "\n");
		out.add(prefix);
		out.add(terminated ? line : line);
		if (!terminated) {
			out.add("\n");
			out.add("\\ No newline at end of file\n");
		}
	}

	static function range(start:Int, count:Int):String return (count == 0 ? start : start + 1) + "," + count;

	static function quotePath(prefix:String, path:Bytes):String {
		var raw = prefix + path.toString(), special = false;
		for (index in 0...raw.length) {
			var code = raw.charCodeAt(index);
			if (code < 32 || code >= 127 || code == 34 || code == 92) { special = true; break; }
		}
		if (!special) return raw;
		var buffer = new haxe.io.BytesBuffer();
		buffer.addString(prefix);
		buffer.add(path);
		var bytes = buffer.getBytes(), out = new StringBuf();
		out.add('"');
		for (index in 0...bytes.length) {
			var value = bytes.get(index);
			switch value {
				case 9: out.add("\\t");
				case 10: out.add("\\n");
				case 13: out.add("\\r");
				case 34: out.add("\\\"");
				case 92: out.add("\\\\");
				default:
					if (value < 32 || value >= 127) {
						out.add("\\");
						out.add(StringTools.lpad(StringTools.hex(value), "0", 3));
					} else out.addChar(value);
			}
		}
		out.add('"');
		return out.toString();
	}
}
