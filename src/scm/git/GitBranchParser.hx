package scm.git;

import haxe.io.Bytes;
import scm.ScmBranch;

/** Parses tab-delimited fields emitted by `git for-each-ref`. */
class GitBranchParser {
	public static function parse(output:Bytes):Array<ScmBranch> {
		if (output == null) throw "Git branch list is missing";
		var result:Array<ScmBranch> = [], seen:Map<String, Bool> = [];
		for (record in output.toString().split("\n")) {
			if (record.length == 0) continue;
			var fields = record.split("\t");
			if (fields.length < 3) throw "Git returned a malformed branch ref";
			var reference = fields[0], marker = fields[1], symbolicTarget = fields[2];
			if (symbolicTarget.length > 0) continue;
			var remote = false, name:Null<String> = null;
			if (StringTools.startsWith(reference, "refs/heads/")) name = reference.substring("refs/heads/".length);
			else if (StringTools.startsWith(reference, "refs/remotes/")) {
				remote = true;
				name = reference.substring("refs/remotes/".length);
			}
			if (name == null || name.length == 0 || seen.exists(reference)) continue;
			seen.set(reference, true);
			result.push(new ScmBranch(reference, name, remote, marker == "*"));
			if (result.length > 4096) throw "Git branch list exceeds the 4096-ref response limit";
		}
		return result;
	}
}
