package scm;

import haxe.io.Bytes;

class ScmResource {
	public final path:String;
	public final originalPath:Null<String>;
	/** Retained for exact pathspecs and to avoid lossy parsing of Unix filenames. */
	public final pathBytes:Bytes;
	public final originalPathBytes:Null<Bytes>;
	public final changeKind:ScmChangeKind;
	public final conflictKind:Null<ScmConflictKind>;
	/** Porcelain v2 submodule state, e.g. N... or S.CU. */
	public final submoduleStatus:String;
	public final renameScore:Null<Int>;

	public function new(pathBytes:Bytes, changeKind:ScmChangeKind, ?originalPathBytes:Bytes, ?conflictKind:ScmConflictKind,
			submoduleStatus:String = "N...", ?renameScore:Int) {
		this.pathBytes = pathBytes.sub(0, pathBytes.length);
		this.originalPathBytes = originalPathBytes == null ? null : originalPathBytes.sub(0, originalPathBytes.length);
		path = ScmPath.display(this.pathBytes);
		originalPath = this.originalPathBytes == null ? null : ScmPath.display(this.originalPathBytes);
		this.changeKind = changeKind;
		this.conflictKind = conflictKind;
		this.submoduleStatus = submoduleStatus;
		this.renameScore = renameScore;
	}
}
