package scm;

/** Optional Git repository handle support for reading the configured origin. */
interface ScmOriginHandle {
	public function origin(generation:Int, complete:ScmJobResult<String>->Void):ScmJob<String>;
}
