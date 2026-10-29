package workspace.client;

/**
	Which files and repositories an Agent session may reach. A session always reaches its workspace root. With local file
	access it also reaches its own folder: a Workbench group's folder may be any existing folder, inside the workspace or
	not, and the session's links, images, context files and repository live there. A remote attachment stays bounded by
	the workspace root, the only part of the host its file service shares.

	`relative` is the containment test, returning the path below a root or null outside it: SessionLinkTarget.relativeWithin
	for host paths, or a file-system aware one for local paths. Callers resolve `..` and links before asking.
**/
class SessionFileScope {
	/** Whether a session in `cwd` may open `path`. */
	public static function allows(root:String, cwd:String, path:String, localFiles:Bool,
			relative:(String, String)->Null<String>):Bool {
		if (relative(root, path) != null) return true;
		return localFiles && cwd != null && cwd.length > 0 && relative(cwd, path) != null;
	}

	/**
		Whether a session in `cwd` may act on the repository at `repositoryRoot`, which holds `cwd`. Inside the workspace the
		repository must lie within the root. A local session whose folder is outside the workspace may use the repository
		that holds its folder, wherever that repository starts.
	**/
	public static function allowsRepository(root:String, cwd:String, repositoryRoot:String, localFiles:Bool,
			relative:(String, String)->Null<String>):Bool {
		if (relative(repositoryRoot, cwd) == null) return false;
		if (relative(root, repositoryRoot) != null) return true;
		return localFiles && relative(root, cwd) == null;
	}
}
