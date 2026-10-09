package scm;

interface ScmRepositoryHandle {
	public function repository():ScmRepository;
	public function features():ScmFeatures;
	public function refresh(generation:Int, complete:ScmJobResult<ScmSnapshot>->Void):ScmJob<ScmSnapshot>;
	public function original(reference:ScmRef, path:String, generation:Int, complete:ScmJobResult<ScmBlob>->Void):ScmJob<ScmBlob>;
	public function apply(operation:ScmOperation, generation:Int, complete:ScmJobResult<ScmApplyResult>->Void):ScmJob<ScmApplyResult>;
	public function dispose():Void;
}
