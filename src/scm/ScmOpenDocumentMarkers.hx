package scm;

import editor.BufferSubscription;
import editor.Document;
import jobs.JobHandle;
import jobs.JobScheduler;
import plugin.PluginGutterMarkerKind;
import plugin.PluginGutterMarkerRegistry;

/** Debounced SCM comparison between one open buffer and its index blob. */
class ScmOpenDocumentMarkers {
	final source:ScmSource;
	final repositoryId:String;
	final path:haxe.io.Bytes;
	final document:Document;
	final owner:String;
	final registry:PluginGutterMarkerRegistry;
	final scheduler:JobScheduler;
	final maxBytes:Int;
	final onChanged:Void->Void;
	final subscription:BufferSubscription;
	var baseRevision:String = "";
	var baseSnapshot:Null<ScmSnapshot>;
	var baseText:Null<String>;
	var baseLoaded:Bool = false;
	var baseRequestGeneration:Int = 0;
	var baseRequest:Null<ScmJob<ScmBlob>>;
	var pending:Null<JobHandle>;
	var generation:Int = 0;
	var dueAt:Float = 0.0;
	var computedStateId:Int = -1;
	var disposed:Bool = false;
	var wasNeeded:Bool = false;
	var wasUntracked:Bool = false;
	var latestHunks:Array<LineDiffHunk> = [];

	public function new(source:ScmSource, repositoryId:String, path:haxe.io.Bytes, document:Document,
		owner:String, registry:PluginGutterMarkerRegistry, scheduler:JobScheduler, maxBytes:Int,
		onChanged:Void->Void) {
		if (source == null || repositoryId == null || repositoryId.length == 0 || path == null ||
			document == null || owner == null || owner.length == 0 || registry == null || scheduler == null)
			throw "SCM document markers require a source, repository, path, document and services";
		this.source = source;
		this.repositoryId = repositoryId;
		this.path = path.sub(0, path.length);
		this.document = document;
		this.owner = owner;
		this.registry = registry;
		this.scheduler = scheduler;
		this.maxBytes = maxBytes < 0 ? 0 : maxBytes;
		this.onChanged = onChanged == null ? function() {} : onChanged;
		subscription = document.buffer.subscribe(function(_) {
			if (disposed) return;
			generation++;
			computedStateId = -1;
			if (pending != null) scheduler.cancel(pending);
			pending = null;
			dueAt = Sys.time() + 0.1;
		});
	}

	/** Called from the UI pump; index reads stay cached for one snapshot revision. */
	public function update(snapshot:ScmSnapshot, needed:Bool, untracked:Bool, now:Float):Void {
		if (disposed) return;
		if (snapshot == null || !needed) {
			wasNeeded = false;
			wasUntracked = untracked;
			cancelDiff();
			baseRequestGeneration++;
			if (baseRequest != null) baseRequest.cancel();
			baseRequest = null;
			baseLoaded = false;
			baseText = null;
			computedStateId = -1;
			clearMarkers();
			return;
		}

		// The revision string is only needed when the snapshot object changed.
		var revision = snapshot == baseSnapshot ? baseRevision : haxe.Int64.toStr(snapshot.revision);
		baseSnapshot = snapshot;
		if (!wasNeeded || revision != baseRevision || untracked != wasUntracked) {
			baseRevision = revision;
			wasNeeded = true;
			wasUntracked = untracked;
			generation++;
			cancelDiff();
			baseRequestGeneration++;
			if (baseRequest != null) baseRequest.cancel();
			baseRequest = null;
			baseLoaded = untracked;
			baseText = untracked ? "" : null;
			computedStateId = -1;
			dueAt = now;
			clearMarkers();
		}
		if (untracked) {
			baseLoaded = true;
			baseText = "";
		} else if (!baseLoaded && baseRequest == null) {
			loadBase(revision);
		}
		if (baseLoaded && baseText != null && now >= dueAt && computedStateId != document.buffer.stateId && pending == null) {
			var nextText = document.buffer.text;
			var stateId = document.buffer.stateId;
			if (haxe.io.Bytes.ofString(nextText).length > maxBytes) {
				computedStateId = stateId;
				clearMarkers();
			} else startDiff(nextText, stateId);
		}
	}

	public function dispose():Void {
		if (disposed) return;
		disposed = true;
		generation++;
		baseRequestGeneration++;
		if (baseRequest != null) baseRequest.cancel();
		baseRequest = null;
		cancelDiff();
		subscription.release();
		clearMarkers();
	}

	/** Returns the exact patch represented by the marker at an editor line, if its diff is ready. */
	public function patchForLine(line:Int):Null<haxe.io.Bytes> {
		if (disposed || baseText == null || latestHunks.length == 0) return null;
		for (index in 0...latestHunks.length) {
			var hunk = latestHunks[index];
			var lineCount = document.buffer.lineCount();
			if (lineCount == 0) return null;
			var start = hunk.newCount == 0
				? Std.int(Math.min(lineCount - 1, Math.max(0, hunk.newStart)))
				: hunk.newStart;
			var end = hunk.newCount == 0 ? start : hunk.newStart + hunk.newCount;
			if (line >= start && (hunk.newCount == 0 ? line == start : line < end))
				return ScmPatchBuilder.build(path, baseText, document.buffer.text, latestHunks, index);
		}
		return null;
	}

	public function getRepositoryId():String return repositoryId;
	public function getPathBytes():haxe.io.Bytes return path.sub(0, path.length);

	function loadBase(revision:String):Void {
		var expected = ++baseRequestGeneration;
		var requestedText = document.buffer.text;
		var request = source.originalBytes(repositoryId, ScmRef.Index, path, function(result) {
			if (disposed || expected != baseRequestGeneration || revision != baseRevision) return;
			baseRequest = null;
			if (result.error != null || result.value == null || result.value.binary || result.value.bytes.length > maxBytes) {
				baseLoaded = true;
				baseText = null;
				clearMarkers();
				return;
			}
			baseLoaded = true;
			baseText = result.value.bytes.toString();
			if (document.buffer.text == requestedText && dueAt <= Sys.time()) dueAt = Sys.time();
		});
		baseRequest = request.complete || request.cancelled ? null : request;
	}

	function startDiff(nextText:String, stateId:Int):Void {
		var previous = baseText;
		if (previous == null || disposed) return;
		var expected = ++generation;
		var task = new LineDiff(previous, nextText, function(hunks) {
			if (disposed || expected != generation) return;
			pending = null;
			computedStateId = stateId;
			publish(hunks);
		});
		pending = scheduler.schedule(task);
	}

	function publish(hunks:Array<LineDiffHunk>):Void {
		latestHunks = hunks.copy();
		registry.removeOwner(owner);
		var lineCount = document.buffer.lineCount();
		if (lineCount == 0) { onChanged(); return; }
		var index = 0;
		for (hunk in hunks) {
			if (hunk.newCount == 0) {
				var line = Std.int(Math.min(lineCount - 1, Math.max(0, hunk.newStart)));
				var kind = hunk.newStart >= lineCount ? PluginGutterMarkerKind.DeletedBelow : PluginGutterMarkerKind.DeletedAbove;
				registry.add(owner, "deleted:" + index++, document, line, line, kind);
				continue;
			}
			var start = Std.int(Math.max(0, hunk.newStart));
			var end = Std.int(Math.min(lineCount - 1, hunk.newStart + hunk.newCount - 1));
			if (end >= start) registry.add(owner, "changed:" + index++, document, start, end,
				hunk.oldCount == 0 ? PluginGutterMarkerKind.Added : PluginGutterMarkerKind.Modified);
		}
		onChanged();
	}

	function cancelDiff():Void {
		if (pending != null) scheduler.cancel(pending);
		pending = null;
	}

	function clearMarkers():Void {
		latestHunks = [];
		var before = registry.revision;
		registry.removeOwner(owner);
		if (registry.revision != before) onChanged();
	}
}
