package scm.fake;

import scm.ScmBlob;
import scm.ScmError;
import scm.ScmOperation;
import scm.ScmRef;
import scm.ScmSnapshot;

/** Mutable fixture input for FakeScmProvider; never used by a production provider. */
class FakeScmRepositoryScript {
	public final repository:scm.ScmRepository;
	public final features:scm.ScmFeatures;
	public final snapshots:Array<ScmSnapshot>;
	public final blobs:Map<String, ScmBlob> = [];
	public final failures:Map<String, Array<ScmError>> = [];
	public final operations:Array<ScmOperation> = [];
	public var latencySteps:Int;
	public var refreshCalls:Int = 0;
	var snapshotCursor:Int = 0;

	public function new(repository:scm.ScmRepository, features:scm.ScmFeatures, snapshots:Array<ScmSnapshot>, latencySteps:Int = 0) {
		this.repository = repository;
		this.features = features;
		this.snapshots = snapshots.copy();
		this.latencySteps = latencySteps;
	}

	public function setBlob(reference:ScmRef, path:String, blob:ScmBlob):Void blobs.set(blobKey(reference, path), blob);
	public function failNext(action:String, error:ScmError):Void {
		var queue = failures.get(action);
		if (queue == null) { queue = []; failures.set(action, queue); }
		queue.push(error);
	}

	public function takeFailure(action:String):Null<ScmError> {
		var queue = failures.get(action);
		if (queue == null || queue.length == 0) return null;
		var failure = queue.shift();
		if (queue.length == 0) failures.remove(action);
		return failure;
	}

	public function nextSnapshot():Null<ScmSnapshot> {
		if (snapshots.length == 0) return null;
		var index = snapshotCursor < snapshots.length ? snapshotCursor++ : snapshots.length - 1;
		return snapshots[index];
	}

	public function latestSnapshot():Null<ScmSnapshot>
		return snapshots.length == 0 ? null : snapshots[snapshots.length - 1];

	public static function blobKey(reference:ScmRef, path:String):String {
		var key = switch reference {
			case Head: "head";
			case Index: "index";
			case Commit(oid): "commit:" + oid;
			case ConflictStage(stage): "stage:" + stage;
		};
		return key + ":" + path.length + ":" + path;
	}
}
