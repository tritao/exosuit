package scm;

import haxe.io.Bytes;
import editor.BufferSubscription;
import editor.Document;
import jobs.JobHandle;
import jobs.JobScheduler;

/** A stable, read-only presentation of one source-control comparison. */
class ScmDiffDocument {
	public final id:String;
	public final repositoryId:String;
	public final path:String;
	public final reference:String;
	public var baseRevision(default, null):String;
	public var text(default, null):String = "";
	public var alignedOldText(default, null):String = "";
	public var alignedCurrentText(default, null):String = "";
	public var alignedOldChangedLines(default, null):Array<Int> = [];
	public var alignedCurrentChangedLines(default, null):Array<Int> = [];
	public var hunks(default, null):Array<LineDiffHunk> = [];
	public var addedLines(default, null):Array<Int> = [];
	public var removedLines(default, null):Array<Int> = [];
	public var hunkLines(default, null):Array<Int> = [];
	public var oldLineAtOutput(default, null):Array<Int> = [];
	public var newLineAtOutput(default, null):Array<Int> = [];
	public var onChanged:Void->Void = function() {};

	final scheduler:JobScheduler;
	final liveDocument:Null<Document>;
	final liveSubscription:Null<BufferSubscription>;
	var oldText:String;
	var currentText:String;
	var generation:Int = 0;
	var pending:Null<JobHandle>;
	var disposed:Bool = false;

	public function new(scheduler:JobScheduler, repositoryId:String, path:String, reference:String,
		baseRevision:String, oldText:String, currentText:String, ?liveDocument:Document) {
		this.scheduler = scheduler;
		this.repositoryId = repositoryId;
		this.path = path;
		this.reference = reference;
		this.baseRevision = baseRevision == null ? "" : baseRevision;
		this.oldText = oldText == null ? "" : oldText;
		this.currentText = liveDocument == null ? (currentText == null ? "" : currentText) : liveDocument.buffer.text;
		this.liveDocument = liveDocument;
		id = "scm-diff:" + repositoryId + ":" + path + ":" + reference;
		if (liveDocument != null)
			liveSubscription = liveDocument.buffer.subscribe(function(_) refresh(this.oldText, liveDocument.buffer.text, this.baseRevision));
		else liveSubscription = null;
		refresh(this.oldText, this.currentText, this.baseRevision);
	}

	/** Replace either side of the comparison after the repository base advances. */
	public function update(baseRevision:String, oldText:String, currentText:String):Void {
		if (disposed) return;
		this.baseRevision = baseRevision == null ? "" : baseRevision;
		this.oldText = oldText == null ? "" : oldText;
		this.currentText = liveDocument == null ? (currentText == null ? "" : currentText) : liveDocument.buffer.text;
		refresh(this.oldText, this.currentText, this.baseRevision);
	}

	public function dispose():Void {
		if (disposed) return;
		disposed = true;
		generation++;
		if (pending != null) scheduler.cancel(pending);
		pending = null;
		if (liveSubscription != null) liveSubscription.release();
	}

	public function hunkLine(fromLine:Int, direction:Int):Int {
		if (hunkLines.length == 0) return -1;
		if (direction >= 0) {
			for (line in hunkLines) if (line > fromLine) return line;
			return hunkLines[0];
		}
		var index = hunkLines.length - 1;
		while (index >= 0) {
			if (hunkLines[index] < fromLine) return hunkLines[index];
			index--;
		}
		return hunkLines[hunkLines.length - 1];
	}

	public function sourceLine(outputLine:Int):Int {
		if (outputLine >= 0 && outputLine < newLineAtOutput.length && newLineAtOutput[outputLine] >= 0)
			return newLineAtOutput[outputLine];
		return outputLine >= 0 && outputLine < oldLineAtOutput.length ? oldLineAtOutput[outputLine] : -1;
	}

	public function hunkIndexAtLine(outputLine:Int):Int {
		var selected = -1;
		for (index in 0...hunkLines.length) {
			if (hunkLines[index] > outputLine) break;
			selected = index;
		}
		return selected;
	}

	public function patchForHunk(index:Int, pathBytes:Bytes):Null<Bytes>
		return ScmPatchBuilder.build(pathBytes, oldText, currentText, hunks, index);

	function refresh(previous:String, next:String, revision:String):Void {
		if (disposed) return;
		oldText = previous;
		currentText = next;
		baseRevision = revision;
		if (pending != null) scheduler.cancel(pending);
		var expected = ++generation;
		var task = new LineDiff(previous, next, function(result) {
			if (disposed || expected != generation) return;
			pending = null;
			hunks = result;
			var rendered = render(previous, next, result);
			var aligned = renderAligned(previous, next, result);
			text = rendered.text;
			alignedOldText = aligned.oldText;
			alignedCurrentText = aligned.currentText;
			alignedOldChangedLines = aligned.oldChanged;
			alignedCurrentChangedLines = aligned.currentChanged;
			addedLines = rendered.added;
			removedLines = rendered.removed;
			hunkLines = rendered.hunks;
			oldLineAtOutput = rendered.oldLines;
			newLineAtOutput = rendered.newLines;
			baseRevision = revision;
			onChanged();
		});
		pending = scheduler.schedule(task);
	}

	function render(previous:String, next:String, changes:Array<LineDiffHunk>):ScmRenderedDiff {
		if (changes.length == 0) return new ScmRenderedDiff("No changes\n", [], [], [], [], [], []);
		var oldLines = LineDiff.splitLines(previous), newLines = LineDiff.splitLines(next);
		var width = Std.string(Math.max(oldLines.length, newLines.length)).length;
		var output:Array<String> = [], added:Array<Int> = [], removed:Array<Int> = [], starts:Array<Int> = [];
		var outputOld:Array<Int> = [], outputNew:Array<Int> = [];
		var cursorOld = 0, cursorNew = 0, index = 0;

		function emit(oldLine:Int, newLine:Int, marker:String, content:String):Void {
			var oldLabel = oldLine < 0 ? "" : pad(oldLine + 1, width);
			var newLabel = newLine < 0 ? "" : pad(newLine + 1, width);
			output.push(oldLabel + " " + newLabel + " " + marker + " " + withoutEol(content));
			outputOld.push(oldLine);
			outputNew.push(newLine);
			if (marker == "+") added.push(output.length - 1);
			if (marker == "-") removed.push(output.length - 1);
		}

		while (index < changes.length) {
			var first = index;
			var startOld = Std.int(Math.max(0, changes[index].oldStart - 3));
			var startNew = Std.int(Math.max(0, changes[index].newStart - 3));
			var endOld = Std.int(Math.min(oldLines.length, changes[index].oldStart + changes[index].oldCount + 3));
			var endNew = Std.int(Math.min(newLines.length, changes[index].newStart + changes[index].newCount + 3));
			index++;
			while (index < changes.length && changes[index].oldStart - 3 <= endOld && changes[index].newStart - 3 <= endNew) {
				endOld = Std.int(Math.min(oldLines.length, changes[index].oldStart + changes[index].oldCount + 3));
				endNew = Std.int(Math.min(newLines.length, changes[index].newStart + changes[index].newCount + 3));
				index++;
			}
			var last = index - 1;
			while (first <= last && (cursorOld < startOld || cursorNew < startNew)) {
				cursorOld++;
				cursorNew++;
			}
			var oldCount = endOld - startOld, newCount = endNew - startNew;
			output.push("\t\t@@ -" + range(startOld, oldCount) + " +" + range(startNew, newCount) + " @@");
			outputOld.push(-1);
			outputNew.push(-1);
			starts.push(output.length - 1);
			var hunkIndex = first;
			while (hunkIndex <= last) {
				var hunk = changes[hunkIndex];
				while (cursorOld < hunk.oldStart) {
					emit(cursorOld, cursorNew, " ", oldLines[cursorOld]);
					cursorOld++;
					cursorNew++;
				}
				for (offset in 0...hunk.oldCount) emit(cursorOld + offset, -1, "-", oldLines[cursorOld + offset]);
				for (offset in 0...hunk.newCount) emit(-1, cursorNew + offset, "+", newLines[cursorNew + offset]);
				cursorOld += hunk.oldCount;
				cursorNew += hunk.newCount;
				hunkIndex++;
			}
			while (cursorOld < endOld && cursorNew < endNew) {
				emit(cursorOld, cursorNew, " ", oldLines[cursorOld]);
				cursorOld++;
				cursorNew++;
			}
		}
		return new ScmRenderedDiff(output.join("\n") + "\n", added, removed, starts, outputOld, outputNew, changes.copy());
	}

	function renderAligned(previous:String, next:String, changes:Array<LineDiffHunk>):ScmAlignedDiff {
		var oldLines = LineDiff.splitLines(previous), newLines = LineDiff.splitLines(next);
		var oldOutput:Array<String> = [], newOutput:Array<String> = [], oldChanged:Array<Int> = [], newChanged:Array<Int> = [];
		var oldCursor = 0, newCursor = 0;
		for (hunk in changes) {
			while (oldCursor < hunk.oldStart || newCursor < hunk.newStart) {
				oldOutput.push(oldCursor < hunk.oldStart ? oldLines[oldCursor++] : "\n");
				newOutput.push(newCursor < hunk.newStart ? newLines[newCursor++] : "\n");
			}
			var count = Std.int(Math.max(hunk.oldCount, hunk.newCount)), start = oldOutput.length;
			for (index in 0...count) {
				oldOutput.push(index < hunk.oldCount ? oldLines[oldCursor + index] : "\n");
				newOutput.push(index < hunk.newCount ? newLines[newCursor + index] : "\n");
			}
			if (hunk.oldCount > 0) for (index in 0...count) oldChanged.push(start + index);
			if (hunk.newCount > 0) for (index in 0...count) newChanged.push(start + index);
			oldCursor += hunk.oldCount;
			newCursor += hunk.newCount;
		}
		while (oldCursor < oldLines.length || newCursor < newLines.length) {
			oldOutput.push(oldCursor < oldLines.length ? oldLines[oldCursor++] : "\n");
			newOutput.push(newCursor < newLines.length ? newLines[newCursor++] : "\n");
		}
		return new ScmAlignedDiff(oldOutput.join(""), newOutput.join(""), oldChanged, newChanged);
	}

	static function range(start:Int, count:Int):String return (count == 0 ? start : start + 1) + "," + count;
	static function pad(value:Int, width:Int):String {
		var result = Std.string(value);
		while (result.length < width) result = " " + result;
		return result;
	}
	static function withoutEol(value:String):String
		return StringTools.endsWith(value, "\n") ? value.substring(0, value.length - 1) : value;
}

private class ScmAlignedDiff {
	public final oldText:String;
	public final currentText:String;
	public final oldChanged:Array<Int>;
	public final currentChanged:Array<Int>;
	public function new(oldText:String, currentText:String, oldChanged:Array<Int>, currentChanged:Array<Int>) {
		this.oldText = oldText;
		this.currentText = currentText;
		this.oldChanged = oldChanged;
		this.currentChanged = currentChanged;
	}
}

private class ScmRenderedDiff {
	public final text:String;
	public final added:Array<Int>;
	public final removed:Array<Int>;
	public final hunks:Array<Int>;
	public final oldLines:Array<Int>;
	public final newLines:Array<Int>;
	public final changes:Array<LineDiffHunk>;
	public function new(text:String, added:Array<Int>, removed:Array<Int>, hunks:Array<Int>, oldLines:Array<Int>, newLines:Array<Int>, changes:Array<LineDiffHunk>) {
		this.text = text; this.added = added; this.removed = removed; this.hunks = hunks;
		this.oldLines = oldLines; this.newLines = newLines; this.changes = changes;
	}
}
