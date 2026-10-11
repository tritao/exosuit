package scm;

import haxe.io.Bytes;
import haxe.Int64;

typedef ScmApplyCompletion = ScmJobResult<ScmApplyResult>->Void;

/** Client-facing source for local or workspace-hosted SCM state. */
interface ScmSource {
	/** Stable identity for the root and authority that own this source. */
	public function identity():String;
	public function isRemote():Bool;
	public function connected():Bool;
	public function repositories():Array<ScmRepository>;
	public function repository(repositoryId:String):Null<ScmRepository>;
	public function features(repositoryId:String):Null<ScmFeatures>;
	public function branches(repositoryId:String, complete:ScmJobResult<Array<ScmBranch>>->Void):ScmJob<Array<ScmBranch>>;
	/** Whether the current authority may mutate this repository. */
	public function canWrite(repositoryId:String):Bool;
	/** Whether the current authority may run Git network operations. */
	public function canUseRemotes(repositoryId:String):Bool;
	public function snapshot(repositoryId:String):Null<ScmSnapshot>;
	public function error(repositoryId:String):Null<ScmError>;
	public function discover(complete:ScmJobResult<Array<ScmRepository>>->Void):ScmJob<Array<ScmRepository>>;
	public function refreshNow(repositoryId:String):Bool;
	public function originalBytes(repositoryId:String, reference:ScmRef, path:Bytes,
		complete:ScmJobResult<ScmBlob>->Void):ScmJob<ScmBlob>;
	public function apply(repositoryId:String, operationId:String, expectedRevision:Int64, operation:ScmOperation,
		complete:ScmApplyCompletion):ScmJob<ScmApplyResult>;
	public function trust(repositoryId:String, complete:ScmJobResult<Bool>->Void):ScmJob<Bool>;
	public function subscribe(listener:(ScmRepository, Null<ScmSnapshot>)->Void):Void->Void;
	/** RPC sources use this to detect reconnects and advance watches. */
	public function poll():Void;
	public function dispose():Void;
}
