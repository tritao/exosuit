package scm;

import haxe.Int64;

class ScmSnapshot {
	public final revision:Int64;
	public final head:ScmHead;
	public final groups:Array<ScmGroup>;
	public final truncated:Bool;

	public function new(revision:Int64, head:ScmHead, groups:Array<ScmGroup>, truncated:Bool = false) {
		this.revision = revision;
		this.head = head;
		this.groups = groups.copy();
		this.groups.sort(function(a, b) return rank(a.id) - rank(b.id));
		this.truncated = truncated;
	}

	static function rank(id:ScmGroupId):Int
		return switch id {
			case ScmGroupId.Merge: 0;
			case ScmGroupId.Index: 1;
			case ScmGroupId.WorkingTree: 2;
			case ScmGroupId.Untracked: 3;
			default: 4;
		};
}
