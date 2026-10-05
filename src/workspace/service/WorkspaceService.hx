package workspace.service;

import haxeon.rpc.RpcConnection;
import workspace.service.WorkspaceProtocol;
import workspace.service.WorkspacePersistence;

private typedef StoredOperation = {var request:RenameGroup; var outcome:RenameResult;}
private typedef Observer = {var connection:RpcConnection; var watching:Bool; var granted:Bool;}

/** Bounded single-event-loop catalog. State and operation outcomes share one epoch.
 * Optional persistence commits state and outcomes before responding/publishing. */
class WorkspaceService {
	public final id:String;
	public final epoch:String;

	final persistence:Null<WorkspacePersistence>;
	var storageFailed:Bool = false;

	final groups:Map<String, WorkspaceGroup> = [];
	final operations:Map<String, StoredOperation> = [];
	final history:Array<WorkspaceEvent> = [];
	final observers:Array<Observer> = [];
	final historyLimit:Int;
	final operationLimit:Int;
	final clientLimit:Int;
	var operationCount:Int = 0;
	var sequence:Int = 0;

	public function new(id:String, epoch:String, initial:Array<WorkspaceGroup>, historyLimit:Int = 32, operationLimit:Int = 256, clientLimit:Int = 16,
			?persistence:WorkspacePersistence) {
		this.persistence = persistence;
		var stored = persistence == null ? null : persistence.load();
		if (stored != null) {
			epoch = stored.snapshot.epoch;
			initial = stored.snapshot.groups;
		}
		if (!validId(id) || !validId(epoch) || initial == null || initial.length > 32 || historyLimit < 1 || historyLimit > 32 || operationLimit < 1
			|| clientLimit < 1)
			throw "Invalid workspace service limits";
		this.id = id;
		this.epoch = epoch;
		this.historyLimit = historyLimit;
		this.operationLimit = operationLimit;
		this.clientLimit = clientLimit;
		for (group in initial) {
			if (group == null || !validId(group.id) || !validName(group.name) || group.revision < 1 || group.cwd != null && group.cwd.length > 1024
				|| groups.exists(group.id))
				throw "Invalid workspace group";
			groups.set(group.id, WorkspaceProtocol.copyGroup(group));
		}
		if (stored != null)
			restore(stored);
	}

	function restore(stored:WorkspaceStoredState):Void {
		if (stored.snapshot.cursor < 0
			|| stored.operations == null
			|| stored.events == null
			|| stored.operations.length > operationLimit
			|| stored.events.length > historyLimit
			|| stored.operations.length != stored.snapshot.cursor)
			throw "Invalid persisted workspace bounds";
		var latest:Map<String, WorkspaceGroup> = [];
		var expected = 1;
		for (entry in stored.operations) {
			if (entry == null || entry.request == null || entry.outcome == null || entry.outcome.group == null)
				throw "Missing persisted operation";
			var request = entry.request, outcome = entry.outcome;
			var previous = latest.get(request.group);
			if (request.workspace != id
				|| request.epoch != epoch
				|| !validId(request.operation)
				|| !validId(request.group)
				|| !validName(request.name)
				|| request.expectedRevision < 1
				|| request.expectedRevision == 0x7fffffff
				|| outcome.epoch != epoch
				|| outcome.operation != request.operation
				|| outcome.sequence != expected
				|| outcome.group.id != request.group
				|| outcome.group.name != request.name
				|| outcome.group.revision != request.expectedRevision + 1
				|| operations.exists(request.operation)
				|| !groups.exists(request.group)
				|| outcome.group.cwd != groups.get(request.group).cwd
				|| previous != null
				&& request.expectedRevision != previous.revision)
				throw "Invalid persisted operation";
			operations.set(request.operation, {request: request, outcome: outcome});
			latest.set(request.group, outcome.group);
			expected++;
		}
		for (groupId => last in latest) {
			var group = groups.get(groupId);
			if (group == null || group.name != last.name || group.revision != last.revision)
				throw "Persisted group does not match its latest outcome";
		}
		sequence = stored.snapshot.cursor;
		operationCount = stored.operations.length;
		expected = sequence - stored.events.length + 1;
		if (stored.events.length != (sequence < historyLimit ? sequence : historyLimit))
			throw "Invalid persisted event retention";
		for (event in stored.events) {
			if (event == null || event.group == null || event.epoch != epoch || event.sequence != expected)
				throw "Invalid persisted event sequence";
			var outcome = stored.operations[expected - 1].outcome;
			if (event.group.id != outcome.group.id
				|| event.group.name != outcome.group.name
				|| event.group.cwd != outcome.group.cwd
				|| event.group.revision != outcome.group.revision)
				throw "Invalid persisted event sequence";
			history.push(event);
			expected++;
		}
	}

	static function validId(value:String):Bool
		return value != null && value.length > 0 && value.length <= 128;

	static function validName(value:String):Bool
		return value != null && StringTools.trim(value).length > 0 && value.length <= 128;

	function prune():Void {
		var index = observers.length;
		while (index > 0) {
			index--;
			if (!observers[index].granted || !observers[index].connection.isOpen())
				observers.splice(index, 1);
		}
	}

	public function bind(connection:RpcConnection, capabilities:Array<String>):Void->Void {
		prune();
		if (observers.length >= clientLimit)
			throw "Workspace client limit";
		var observer:Observer = {connection: connection, watching: false, granted: true};
		observers.push(observer);
		var read = capabilities.indexOf(WorkspaceProtocol.READ) >= 0;
		var events = capabilities.indexOf(WorkspaceProtocol.EVENTS) >= 0;
		var write = capabilities.indexOf(WorkspaceProtocol.WRITE) >= 0;
		connection.register(WorkspaceProtocol.QUERY, function(request, context) {
			if (storageFailed) {
				context.fail({code: "storage_unavailable", message: "Workspace storage requires recovery", ambiguous: true});
				return;
			}
			if (!observer.granted || !read) {
				context.fail({code: "unauthorized", message: "Read denied", ambiguous: false});
				return;
			}
			if (request == null || !validId(request.workspace)) {
				context.fail({code: "invalid_request", message: "Invalid workspace query", ambiguous: false});
				return;
			}
			if (request.workspace != id) {
				context.fail({code: "unknown_workspace", message: "Unknown workspace", ambiguous: false});
				return;
			}
			context.respond(snapshot());
		});
		connection.register(WorkspaceProtocol.WATCH, function(request, context) {
			if (storageFailed) {
				context.fail({code: "storage_unavailable", message: "Workspace storage requires recovery", ambiguous: true});
				return;
			}
			if (!observer.granted || !read || !events) {
				context.fail({code: "unauthorized", message: "Watch denied", ambiguous: false});
				return;
			}
			if (request == null || request.workspace != id || request.epoch == null || request.cursor < 0) {
				context.fail({code: "invalid_request", message: "Invalid watch", ambiguous: false});
				return;
			}
			// Establish live delivery before the caller fetches a snapshot.
			observer.watching = true;
			var floor = history.length == 0 ? sequence : history[0].sequence - 1;
			var reset = request.epoch != epoch || request.cursor < floor || request.cursor > sequence;
			var replay:Array<WorkspaceEvent> = [];
			if (!reset)
				for (event in history)
					if (event.sequence > request.cursor)
						replay.push(event);
			context.respond({
				epoch: epoch,
				cursor: sequence,
				reset: reset,
				events: replay
			});
		});
		connection.register(WorkspaceProtocol.RENAME, function(request, context) {
			if (storageFailed) {
				context.fail({code: "storage_unavailable", message: "Workspace storage requires recovery", ambiguous: true});
				return;
			}
			if (!observer.granted || !write) {
				context.fail({code: "unauthorized", message: "Rename denied", ambiguous: false});
				return;
			}
			if (request == null || !validId(request.workspace) || !validId(request.epoch)) {
				context.fail({code: "invalid_request", message: "Invalid rename identity", ambiguous: false});
				return;
			}
			if (request.workspace != id || request.epoch != epoch) {
				context.fail({code: "stale_epoch", message: "Workspace epoch changed", ambiguous: true});
				return;
			}
			if (!validId(request.operation) || !validId(request.group) || !validName(request.name) || request.expectedRevision < 1) {
				context.fail({code: "invalid_request", message: "Invalid rename", ambiguous: false});
				return;
			}
			var prior = operations.get(request.operation);
			if (prior != null) {
				if (prior.request.group != request.group
					|| prior.request.name != request.name
					|| prior.request.expectedRevision != request.expectedRevision) {
					context.fail({code: "operation_conflict", message: "Operation id reused", ambiguous: false});
					return;
				}
				context.respond(WorkspaceProtocol.copyOutcome(prior.outcome));
				return;
			}
			var group = groups.get(request.group);
			if (group == null) {
				context.fail({code: "unknown_group", message: "Unknown group", ambiguous: false});
				return;
			}
			if (group.revision != request.expectedRevision) {
				context.fail({code: "stale_revision", message: "Group changed", ambiguous: false});
				return;
			}
			if (operationCount >= operationLimit || sequence == 0x7fffffff || group.revision == 0x7fffffff) {
				context.fail({code: "operation_limit", message: "Operation retention full", ambiguous: false});
				return;
			}
			var updated:WorkspaceGroup = {
				id: group.id,
				name: request.name,
				cwd: group.cwd,
				revision: group.revision + 1
			};
			var outcome:RenameResult = {
				epoch: epoch,
				operation: request.operation,
				sequence: sequence + 1,
				group: updated
			};
			var event:WorkspaceEvent = {epoch: epoch, sequence: outcome.sequence, group: updated};
			if (persistence != null) {
				try
					persistence.commit(request, outcome, event)
				catch (_:Dynamic) {
					storageFailed = true;
					context.fail({code: "storage_failed", message: "Workspace commit failed; reopen storage to reconcile", ambiguous: true});
					return;
				}
			}
			// Durable commit precedes every in-memory update, reply and event.

			groups.set(updated.id, updated);
			sequence++;
			operationCount++;
			operations.set(request.operation, {
				request: {
					workspace: id,
					epoch: epoch,
					operation: request.operation,
					group: request.group,
					expectedRevision: request.expectedRevision,
					name: request.name
				},
				outcome: outcome
			});
			history.push(event);
			if (history.length > historyLimit)
				history.shift();
			// Queue the outcome before events; slow peers are closed by the RPC bounds.
			context.respond(WorkspaceProtocol.copyOutcome(outcome));
			prune();
			for (watcher in observers)
				if (watcher.watching && watcher.granted)
					watcher.connection.notify(WorkspaceProtocol.CHANGED, event, WorkspaceProtocol.encodeEvent);
		});
		connection.register(WorkspaceProtocol.OPERATION, function(request, context) {
			if (storageFailed) {
				context.fail({code: "storage_unavailable", message: "Workspace storage requires recovery", ambiguous: true});
				return;
			}
			if (!observer.granted || !read) {
				context.fail({code: "unauthorized", message: "Outcome lookup denied", ambiguous: false});
				return;
			}
			if (request == null || request.workspace != id || !validId(request.epoch) || !validId(request.operation)) {
				context.fail({code: "invalid_request", message: "Invalid operation query", ambiguous: false});
				return;
			}
			var stored = request.epoch == epoch ? operations.get(request.operation) : null;
			context.respond({known: stored != null, outcome: stored == null ? null : WorkspaceProtocol.copyOutcome(stored.outcome)});
		});
		return function() {
			observer.granted = false;
			observer.watching = false;
			connection.close("authorization_revoked");
			prune();
		};
	}

	public function snapshot():WorkspaceSnapshot {
		var result = [for (group in groups) WorkspaceProtocol.copyGroup(group)];
		result.sort(function(a, b) return Reflect.compare(a.id, b.id));
		return {epoch: epoch, cursor: sequence, groups: result};
	}
}
