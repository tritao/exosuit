package scm;

class ScmRepository {
	public final id:String;
	public final providerId:String;
	public final root:String;
	public final kind:ScmRepositoryKind;
	public final parentId:Null<String>;
	public final trusted:Bool;

	public function new(id:String, providerId:String, root:String, kind:ScmRepositoryKind = ScmRepositoryKind.Worktree,
			?parentId:String, trusted:Bool = false) {
		this.id = id;
		this.providerId = providerId;
		this.root = root;
		this.kind = kind;
		this.parentId = parentId;
		this.trusted = trusted;
	}
}
