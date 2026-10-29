package scm;

/** Optional read-only origin metadata capability. */
interface ScmRemoteReader extends ScmSource {
	public function canReadOrigin(repositoryId:String):Bool;
	public function origin(repositoryId:String, complete:ScmJobResult<String>->Void):ScmJob<String>;
}
