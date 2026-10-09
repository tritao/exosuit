package scm;

interface ScmProvider {
	public function id():String;
	public function detect(root:String, generation:Int, complete:ScmJobResult<Array<ScmRepositoryHandle>>->Void):ScmJob<Array<ScmRepositoryHandle>>;
}
