package scm;

class ScmRepository {
	public final id:String;
	public final providerId:String;
	public final root:String;
	public final kind:ScmRepositoryKind;
	public final parentId:Null<String>;
	public final trusted:Bool;
	/** Case-insensitive file systems by default: Git sets `core.ignorecase` there, and treats it as unset elsewhere. */
	public static final PLATFORM_IGNORES_CASE:Bool = Sys.systemName() == "Windows" || Sys.systemName() == "Mac";
	/** Whether the repository compares paths case-insensitively (Git's `core.ignorecase`, else the platform default). */
	public final ignoreCase:Bool;

	public function new(id:String, providerId:String, root:String, kind:ScmRepositoryKind = ScmRepositoryKind.Worktree,
			?parentId:String, trusted:Bool = false, ?ignoreCase:Bool) {
		this.id = id;
		this.providerId = providerId;
		this.root = root;
		this.kind = kind;
		this.parentId = parentId;
		this.trusted = trusted;
		this.ignoreCase = ignoreCase == null ? PLATFORM_IGNORES_CASE : ignoreCase == true;
	}
}
