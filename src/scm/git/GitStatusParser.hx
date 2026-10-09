package scm.git;

import haxe.io.Bytes;
import scm.ScmChangeKind;
import scm.ScmConflictKind;
import scm.ScmGroup;
import scm.ScmGroupId;
import scm.ScmHead;
import scm.ScmHeadOperation;
import scm.ScmResource;

/** Parses `git status --porcelain=v2 -z --branch` without decoding filenames first. */
class GitStatusParser {
	public static function parse(output:Bytes, upstreamGone:Bool = false, operation:ScmHeadOperation = ScmHeadOperation.None):GitStatusParseResult {
		var records = splitNul(output), branch:Null<String> = null, detached:Null<String> = null, oid:Null<String> = null;
		var unborn = false, upstream:Null<String> = null, ahead = 0, behind = 0;
		var merge:Array<ScmResource> = [], index:Array<ScmResource> = [], working:Array<ScmResource> = [], untracked:Array<ScmResource> = [], ignored:Array<ScmResource> = [];
		var cursor = 0;
		while (cursor < records.length) {
			var record = records[cursor++];
			if (record.length == 0) continue;
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
				continue;
			}
			if (first == 0x3f || first == 0x21) {
				if (record.length < 3 || record.get(1) != 0x20) throw "Malformed porcelain v2 path record";
				var path = record.sub(2, record.length - 2);
				var kind:ScmChangeKind = first == 0x3f ? ScmChangeKind.Untracked : ScmChangeKind.Ignored;
				var resource = new ScmResource(path, kind);
				if (first == 0x3f) untracked.push(resource); else ignored.push(resource);
				continue;
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
					if (scoreText.length < 2 || (scoreText.charAt(0) != "R" && scoreText.charAt(0) != "C")) throw "Malformed porcelain v2 rename score";
					score = Std.parseInt(scoreText.substring(1));
					if (cursor >= records.length) throw "Missing porcelain v2 original path";
					original = records[cursor++];
				}
				appendOrdinary(index, working, path, original, score, submodule, xy);
				continue;
			}
			if (first == 0x75) {
				var fields = splitFields(record, 10);
				if (fields.length != 11 || fields[0].text != "u" || fields[1].text.length != 2)
					throw "Malformed porcelain v2 unmerged record";
				var resource = new ScmResource(fields[10].bytes, ScmChangeKind.Unmerged, null,
					conflictKind(fields[1].text), fields[2].text);
				merge.push(resource);
				continue;
			}
			throw 'Unknown porcelain v2 record type: ' + first;
		}
		var head = new ScmHead(branch, detached, unborn, upstream, ahead, behind, upstreamGone, operation), groups:Array<ScmGroup> = [];
		if (merge.length > 0) groups.push(new ScmGroup(ScmGroupId.Merge, merge));
		if (index.length > 0) groups.push(new ScmGroup(ScmGroupId.Index, index));
		if (working.length > 0) groups.push(new ScmGroup(ScmGroupId.WorkingTree, working));
		if (untracked.length > 0) groups.push(new ScmGroup(ScmGroupId.Untracked, untracked));
		return new GitStatusParseResult(head, groups, ignored);
	}

	static function appendOrdinary(index:Array<ScmResource>, working:Array<ScmResource>, path:Bytes, original:Null<Bytes>, score:Null<Int>, submodule:String, xy:String):Void {
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

	static function splitNul(bytes:Bytes):Array<Bytes> {
		var result:Array<Bytes> = [], start = 0;
		for (index in 0...bytes.length) if (bytes.get(index) == 0) {
			result.push(bytes.sub(start, index - start));
			start = index + 1;
		}
		if (start < bytes.length) result.push(bytes.sub(start, bytes.length - start));
		return result;
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
