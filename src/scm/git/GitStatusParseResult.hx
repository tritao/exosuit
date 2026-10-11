package scm.git;

import scm.ScmGroup;
import scm.ScmHead;
import scm.ScmResource;

class GitStatusParseResult {
	public final head:ScmHead;
	public final groups:Array<ScmGroup>;
	public final ignored:Array<ScmResource>;
	public final truncated:Bool;

	public function new(head:ScmHead, groups:Array<ScmGroup>, ignored:Array<ScmResource>, truncated:Bool = false) {
		this.head = head;
		this.groups = groups.copy();
		this.ignored = ignored.copy();
		this.truncated = truncated;
	}
}
