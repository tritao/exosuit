package scm.git;

import haxe.io.Bytes;
import jobs.JobTask;
import scm.ScmChangeKind;
import scm.ScmConflictKind;
import scm.ScmGroup;
import scm.ScmGroupId;
import scm.ScmHead;
import scm.ScmHeadOperation;
import scm.ScmResource;

/** Incrementally parses `git status --porcelain=v2 -z --branch`. */
class GitStatusParser implements JobTask {
	static inline final MAX_RECORDS_PER_STEP = 256;
	static inline final MAX_STEP_MILLIS = 1.5;

	var input:Null<Bytes>;
	var offset:Int = 0;
	final upstreamGone:Bool;
	final operation:ScmHeadOperation;
	final untrackedLimit:Int;
	final previousSignature:Null<Bytes>;
	final complete:Null<(Null<GitStatusParseResult>, Null<Dynamic>)->Void>;
	var branch:Null<String>;
	var detached:Null<String>;
	var oid:Null<String>;
	var unborn:Bool = false;
	var upstream:Null<String>;
	var ahead:Int = 0;
	var behind:Int = 0;
	var untrackedCount:Int = 0;
	var truncated:Bool = false;
	final merge:Array<ScmResource> = [];
	final index:Array<ScmResource> = [];
	final working:Array<ScmResource> = [];
	final untracked:Array<ScmResource> = [];
	final ignored:Array<ScmResource> = [];
	var finished:Bool = false;
	var cancelled:Bool = false;
	public var value(default, null):Null<GitStatusParseResult>;
	public var error(default, null):Null<Dynamic>;
	public var signatureMatches(default, null):Bool;

	public function new(output:Bytes, upstreamGone:Bool = false, operation:ScmHeadOperation = ScmHeadOperation.None,
			untrackedLimit:Int = -1, ?previousSignature:Bytes,
			?complete:(Null<GitStatusParseResult>, Null<Dynamic>)->Void) {
		input = output;
		this.upstreamGone = upstreamGone;
		this.operation = operation;
		this.untrackedLimit = untrackedLimit;
		this.previousSignature = previousSignature;
		signatureMatches = previousSignature != null && previousSignature.length == output.length;
		this.complete = complete;
	}

	/** Parses a small fixture synchronously. Production refreshes schedule this task. */
	public static function parse(output:Bytes, upstreamGone:Bool = false,
			operation:ScmHeadOperation = ScmHeadOperation.None):GitStatusParseResult {
		var result:Null<GitStatusParseResult> = null, failure:Null<Dynamic> = null;
		var parser = new GitStatusParser(output, upstreamGone, operation,
			-1, null, (value, error) -> { result = value; failure = error; });
		while (!parser.step()) {}
		if (failure != null) throw failure;
		if (result == null) throw "Git status parser returned no result";
		return result;
	}

	public function step():Bool {
		if (finished || cancelled) return true;
		var bytes = input;
		if (bytes == null) { finish(null, "Git status parser lost its input"); return true; }
		var started = Sys.time(), processed = 0;
		try {
			while (offset < bytes.length) {
				var record = nextRecord(bytes);
			if (record.length > 0) parseRecord(record, bytes);
				processed++;
				if (processed % 16 == 0 && (Sys.time() - started) * 1000.0 >= MAX_STEP_MILLIS) break;
				if (processed >= MAX_RECORDS_PER_STEP) break;
			}
			if (offset >= bytes.length) finish(buildResult(), null);
		} catch (failure:Dynamic) {
			finish(null, failure);
		}
		return finished;
	}

	public function cancel():Void {
		if (finished || cancelled) return;
		cancelled = true;
		input = null;
		merge.resize(0);
		index.resize(0);
		working.resize(0);
		untracked.resize(0);
		ignored.resize(0);
	}

	function nextRecord(bytes:Bytes):Bytes {
		var start = offset;
		while (offset < bytes.length && bytes.get(offset) != 0) offset++;
		var end = offset, record = bytes.sub(start, end - start);
		if (offset < bytes.length) offset++;
		compareSignature(bytes, start, offset);
		return record;
	}

	function compareSignature(bytes:Bytes, start:Int, end:Int):Void {
		if (!signatureMatches) return;
		var baseline = previousSignature;
		if (baseline == null) { signatureMatches = false; return; }
		for (index in start...end) if (bytes.get(index) != baseline.get(index)) {
			signatureMatches = false;
			return;
		}
	}

	function parseRecord(record:Bytes, bytes:Bytes):Void {
		var first = record.get(0);
		if (first == 0x23) {
			var header = record.getString(0, record.length);
			if (StringTools.startsWith(header, "# branch.oid ")) {
				oid = header.substring(13);
				unborn = oid == "(initial)";
			} else if (StringTools.startsWith(header, "# branch.head ")) {
				var name = header.substring(14);
				if (name == "(detached)") detached = oid; else branch = name;
			} else if (StringTools.startsWith(header, "# branch.upstream ")) {
				upstream = header.substring(18);
			} else if (StringTools.startsWith(header, "# branch.ab ")) {
				var values = header.substring(12).split(" ");
				if (values.length == 2) {
					ahead = signedCount(values[0], "+");
					behind = signedCount(values[1], "-");
				}
			}
			return;
		}
		if (first == 0x3f || first == 0x21) {
			if (record.length < 3 || record.get(1) != 0x20) throw "Malformed porcelain v2 path record";
			var path = record.sub(2, record.length - 2);
			var kind:ScmChangeKind = first == 0x3f ? ScmChangeKind.Untracked : ScmChangeKind.Ignored;
			var resource = new ScmResource(path, kind);
			if (first == 0x3f) {
				untrackedCount++;
				if (untrackedLimit < 0 || untrackedCount <= untrackedLimit) untracked.push(resource);
				else truncated = true;
			} else ignored.push(resource);
			return;
		}
		if (first == 0x31 || first == 0x32) {
			var count = first == 0x31 ? 8 : 9;
			var fields = splitFields(record, count);
			if (fields.length != count + 1 || fields[0].text != (first == 0x31 ? "1" : "2") || fields[1].text.length != 2)
				throw "Malformed porcelain v2 ordinary record";
			var xy = fields[1].text, submodule = fields[2].text, path = fields[count].bytes;
			var original:Null<Bytes> = null, score:Null<Int> = null;
			if (first == 0x32) {
				var scoreText = fields[8].text;
				if (scoreText.length < 2 || (scoreText.charAt(0) != "R" && scoreText.charAt(0) != "C"))
					throw "Malformed porcelain v2 rename score";
				score = Std.parseInt(scoreText.substring(1));
				if (offset >= bytes.length) throw "Missing porcelain v2 original path";
				original = nextRecord(bytes);
			}
			appendOrdinary(index, working, path, original, score, submodule, xy);
			return;
		}
		if (first == 0x75) {
			var fields = splitFields(record, 10);
			if (fields.length != 11 || fields[0].text != "u" || fields[1].text.length != 2)
				throw "Malformed porcelain v2 unmerged record";
			var resource = new ScmResource(fields[10].bytes, ScmChangeKind.Unmerged, null,
				conflictKind(fields[1].text), fields[2].text);
			merge.push(resource);
			return;
		}
		throw 'Unknown porcelain v2 record type: ' + first;
	}

	function buildResult():GitStatusParseResult {
		var head = new ScmHead(branch, detached, unborn, upstream, ahead, behind, upstreamGone, operation), groups:Array<ScmGroup> = [];
		if (merge.length > 0) groups.push(new ScmGroup(ScmGroupId.Merge, merge, false));
		if (index.length > 0) groups.push(new ScmGroup(ScmGroupId.Index, index, false));
		if (working.length > 0) groups.push(new ScmGroup(ScmGroupId.WorkingTree, working, false));
		if (untracked.length > 0) groups.push(new ScmGroup(ScmGroupId.Untracked, untracked, false));
		return new GitStatusParseResult(head, groups, ignored, truncated);
	}

	function finish(result:Null<GitStatusParseResult>, failure:Null<Dynamic>):Void {
		if (finished || cancelled) return;
		finished = true;
		input = null;
		value = result;
		error = failure;
		if (complete != null) complete(result, failure);
	}

	static function appendOrdinary(index:Array<ScmResource>, working:Array<ScmResource>, path:Bytes, original:Null<Bytes>,
			score:Null<Int>, submodule:String, xy:String):Void {
		var x = xy.charAt(0), y = xy.charAt(1);
		if (x != ".") index.push(new ScmResource(path, kind(x), original, null, submodule, score));
		if (y != ".") working.push(new ScmResource(path, kind(y), original, null, submodule, score));
	}

	static function kind(code:String):ScmChangeKind
		return switch code {
			case "A": ScmChangeKind.Added;
			case "D": ScmChangeKind.Deleted;
			case "R": ScmChangeKind.Renamed;
			case "C": ScmChangeKind.Copied;
			case "T": ScmChangeKind.TypeChanged;
			case "U": ScmChangeKind.Unmerged;
			case "?": ScmChangeKind.Untracked;
			case "!": ScmChangeKind.Ignored;
			default: ScmChangeKind.Modified;
		};

	static function conflictKind(xy:String):ScmConflictKind
		return switch xy {
			case "DD": ScmConflictKind.BothDeleted;
			case "AU": ScmConflictKind.AddedByUs;
			case "UD": ScmConflictKind.DeletedByThem;
			case "UA": ScmConflictKind.AddedByThem;
			case "DU": ScmConflictKind.DeletedByUs;
			case "AA": ScmConflictKind.BothAdded;
			case "UU": ScmConflictKind.BothModified;
			default: ScmConflictKind.Unknown;
		};

	static function signedCount(value:String, marker:String):Int {
		if (!StringTools.startsWith(value, marker)) return 0;
		var parsed = Std.parseInt(value.substring(1));
		return parsed == null || parsed < 0 ? 0 : parsed;
	}

	static function splitFields(record:Bytes, delimiters:Int):Array<{text:String, bytes:Bytes}> {
		var fields:Array<{text:String, bytes:Bytes}> = [], start = 0, found = 0;
		for (index in 0...record.length) {
			if (record.get(index) == 0x20 && found < delimiters) {
				var part = record.sub(start, index - start);
				fields.push({text:part.getString(0, part.length), bytes:part});
				start = index + 1;
				found++;
			}
		}
		var tail = record.sub(start, record.length - start);
		fields.push({text:tail.getString(0, tail.length), bytes:tail});
		return fields;
	}
}
