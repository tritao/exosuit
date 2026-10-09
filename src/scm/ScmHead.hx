package scm;

class ScmHead {
	public final branch:Null<String>;
	public final detachedCommit:Null<String>;
	public final unborn:Bool;
	public final upstream:Null<String>;
	public final ahead:Int;
	public final behind:Int;
	public final upstreamGone:Bool;
	public final operation:ScmHeadOperation;

	public function new(branch:Null<String>, detachedCommit:Null<String>, unborn:Bool, upstream:Null<String>, ahead:Int, behind:Int,
			upstreamGone:Bool, operation:ScmHeadOperation) {
		this.branch = branch;
		this.detachedCommit = detachedCommit;
		this.unborn = unborn;
		this.upstream = upstream;
		this.ahead = ahead;
		this.behind = behind;
		this.upstreamGone = upstreamGone;
		this.operation = operation;
	}
}
