package workspace.client;

/**
	An endpoint whose service answers for more than its own root: a machine workspace's service serves terminals keyed by
	any of the workspace's folders, while `rootPath()` stays the folder it started in.
**/
interface ServedRoots {
	public function servesRoot(path:String):Bool;
}
