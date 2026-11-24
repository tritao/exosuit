package workspace.service;

import haxeon.rpc.RpcConnection;
import haxeon.rpc.RpcError;
import workspace.service.WorkspaceProtocol;
import workspace.service.WorkspacePersistence;

private typedef StoredOperation = {var request:RenameGroup; var outcome:RenameResult;}
private typedef Observer = {var connection:RpcConnection; var granted:Bool;}

/** Bounded single-event-loop catalog. State and operation outcomes share one epoch.
 * Optional persistence commits state and outcomes before responding. Clients learn of changes from the catalog watch. */
class WorkspaceService {
	public final id:String;
	public final epoch:String;
	/** Host-owned check includes every terminal and agent, not a paginated client projection. */
	public var canRemoveGroup:Null<String->Bool>;
	final removedGroups:Map<String, Bool> = [];

	final persistence:Null<WorkspacePersistence>;
	final resolveDirectory:Null<String->Null<String>>;
	var storageFailed:Bool = false;

	final groups:Map<String, WorkspaceGroup> = [];
	final operations:Map<String, StoredOperation> = [];
	final observers:Array<Observer> = [];
	final operationLimit:Int;
	final clientLimit:Int;
	var operationCount:Int = 0;
	var sequence:Int = 0;

	public function new(id:String, epoch:String, initial:Array<WorkspaceGroup>, operationLimit:Int = 256, clientLimit:Int = 16,
			?persistence:WorkspacePersistence, ?resolveDirectory:String->Null<String>) {
		this.resolveDirectory = resolveDirectory;
		this.persistence = persistence;
		var stored = persistence == null ? null : persistence.load();
		if (stored != null) {
			epoch = stored.snapshot.epoch;
			initial = stored.snapshot.groups;
		}
		if (!validId(id) || !validId(epoch) || initial == null || initial.length > 32 || operationLimit < 1
			|| clientLimit < 1)
			throw "Invalid workspace service limits";
		this.id = id;
		this.epoch = epoch;
		this.operationLimit = operationLimit;
		this.clientLimit = clientLimit;
		for (group in initial) {
			if (group == null || !validId(group.id) || !validName(group.name) || group.revision < 1 || group.cwd != null && group.cwd.length > 1024
				|| groups.exists(group.id))
				throw "Invalid workspace group";
			groups.set(group.id, WorkspaceProtocol.copyGroup(group));
		}
		for (group in groups) if (!validHierarchy(group.id, group.parent) || WorkspaceProtocol.order(group.order) < 0 || WorkspaceProtocol.order(group.order) > WorkspaceProtocol.MAX_ORDER) throw "Invalid workspace hierarchy";
		if (stored != null)
			restore(stored);
	}

	function restore(stored:WorkspaceStoredState):Void {
		if (stored.snapshot.cursor < 0
			|| stored.operations == null
			|| stored.operations.length > operationLimit
			|| stored.operations.length != stored.snapshot.cursor)
			throw "Invalid persisted workspace bounds";
		var latest:Map<String, WorkspaceGroup> = [];
		var expected = 1;
		for (entry in stored.operations) {
			if (entry == null || entry.request == null || entry.outcome == null || entry.outcome.group == null)
				throw "Missing persisted operation";
			var request = entry.request, outcome = entry.outcome;
			var previous = latest.get(request.group);
			if (removedGroups.exists(request.group)) throw "Deleted group identity reused";
			if (request.workspace != id
				|| request.epoch != epoch
				|| !validId(request.operation)
				|| !validId(request.group)
				|| !validName(request.name)
				|| (request.action != null && request.action != "create" && request.action != "update" && request.action != "delete")
				|| request.expectedRevision < (request.action == "create" ? 0 : 1)
				|| request.expectedRevision == 0x7fffffff
				|| (request.action == "create" && (request.expectedRevision != 0 || previous != null))
				|| outcome.epoch != epoch
				|| outcome.operation != request.operation
				|| outcome.sequence != expected
				|| outcome.group.id != request.group
				|| outcome.group.name != request.name
				|| outcome.group.revision != request.expectedRevision + 1
				|| operations.exists(request.operation)
				|| (request.action == null && previous != null && (outcome.group.cwd != previous.cwd || outcome.group.parent != previous.parent || WorkspaceProtocol.order(outcome.group.order) != WorkspaceProtocol.order(previous.order)))
				|| (request.action != null && (!persistedDirectory(request.cwd, outcome.group.cwd, previous) || outcome.group.parent != request.parent || WorkspaceProtocol.order(outcome.group.order) != WorkspaceProtocol.order(request.order)))
				|| previous != null
				&& request.expectedRevision != previous.revision)
				throw "Invalid persisted operation";
			operations.set(request.operation, {request: request, outcome: outcome});
			if ((outcome.deleted == true) != (request.action == "delete")) throw "Invalid persisted deletion";
			latest.set(request.group, outcome.group);
			if (outcome.deleted == true) removedGroups.set(request.group, true);
			expected++;
		}
		for (groupId => last in latest) {
			var group = groups.get(groupId);
			if (removedGroups.exists(groupId) ? group != null : group == null || !sameGroup(group, last))
				throw "Persisted group does not match its latest outcome";
		}
		sequence = stored.snapshot.cursor;
		operationCount = stored.operations.length;
	}

	/**
		A tree mutation's stored directory: a newly chosen one is kept in the machine's canonical spelling (mutate), so it
		may differ from the request's text; a kept one, or none, must match exactly.
	**/
	static function persistedDirectory(requested:Null<String>, stored:Null<String>, previous:Null<WorkspaceGroup>):Bool {
		if (requested == stored) return true;
		var kept = previous != null && requested == previous.cwd;
		return requested != null && requested.length > 0 && !kept && stored != null && stored.length > 0;
	}

	static function sameGroup(a:WorkspaceGroup, b:WorkspaceGroup):Bool return a.id == b.id && a.name == b.name
		&& a.cwd == b.cwd && a.parent == b.parent && WorkspaceProtocol.order(a.order) == WorkspaceProtocol.order(b.order) && a.revision == b.revision;
	function validHierarchy(id:String, parent:Null<String>):Bool {
		var seen:Map<String, Bool> = [id => true];
		while (parent != null) {
			if (seen.exists(parent) || !groups.exists(parent)) return false;
			seen.set(parent, true);
			parent = groups.get(parent).parent;
		}
		return true;
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
		var observer:Observer = {connection: connection, granted: true};
		observers.push(observer);
		var read = capabilities.indexOf(WorkspaceProtocol.READ) >= 0;
		var write = capabilities.indexOf(WorkspaceProtocol.WRITE) >= 0;
		connection.register(WorkspaceProtocol.QUERY, function(request, context) {
			if (storageFailed) {
				context.fail(new RpcError("storage_unavailable", "Workspace storage requires recovery", true));
				return;
			}
			if (!observer.granted || !read) {
				context.fail(new RpcError("unauthorized", "Read denied", false));
				return;
			}
			if (request == null || !validId(request.workspace)) {
				context.fail(new RpcError("invalid_request", "Invalid workspace query", false));
				return;
			}
			if (request.workspace != id) {
				context.fail(new RpcError("unknown_workspace", "Unknown workspace", false));
				return;
			}
			context.respond(snapshot());
		});
		function mutate(request:RenameGroup, context:haxeon.rpc.RpcContext<RenameResult>):Void {
			if (storageFailed) {
				context.fail(new RpcError("storage_unavailable", "Workspace storage requires recovery", true));
				return;
			}
			if (!observer.granted || !write || capabilities.indexOf(WorkspaceProtocol.TREE) < 0) {
				context.fail(new RpcError("unauthorized", "Group change denied", false));
				return;
			}
			if (request == null || !validId(request.workspace) || !validId(request.epoch)) {
				context.fail(new RpcError("invalid_request", "Invalid group change identity", false));
				return;
			}
			if (request.workspace != id || request.epoch != epoch) {
				context.fail(new RpcError("stale_epoch", "Workspace epoch changed", true));
				return;
			}
			if (!validId(request.operation) || !validId(request.group) || !validName(request.name) || request.expectedRevision < (request.action == "create" ? 0 : 1)
				|| request.action != "create" && request.action != "update" && request.action != "delete") {
				context.fail(new RpcError("invalid_request", "Invalid group change", false));
				return;
			}
			var prior = operations.get(request.operation);
			if (prior != null) {
				if (WorkspaceProtocol.GROUP.encodeRequest(prior.request).compare(WorkspaceProtocol.GROUP.encodeRequest(request)) != 0) {
					context.fail(new RpcError("operation_conflict", "Operation id reused", false));
					return;
				}
				context.respond(WorkspaceProtocol.copyOutcome(prior.outcome));
				return;
			}
			var group = groups.get(request.group);
			if (request.action == "create" ? group != null || removedGroups.exists(request.group) : group == null) {
				context.fail(new RpcError(request.action == "create" ? "group_exists" : "unknown_group", "Group identity unavailable", false));
				return;
			}
			if ((group == null ? 0 : group.revision) != request.expectedRevision) {
				context.fail(new RpcError("stale_revision", "Group changed", false));
				return;
			}
			if (request.action == "delete") {
				if (capabilities.indexOf(WorkspaceProtocol.REMOVE) < 0 || canRemoveGroup == null) {
					context.fail(new RpcError("unsupported", "Group removal is not available", false)); return;
				}
				for (child in groups) if (child.parent == request.group) {
					context.fail(new RpcError("group_not_empty", "Remove or move child groups first", false)); return;
				}
				var permitsRemoval:String->Bool = cast canRemoveGroup;
				if (!permitsRemoval(request.group)) {
					context.fail(new RpcError("group_not_empty", "Remove or move the group's terminals and agents first", false)); return;
				}
				var deletedGroup:WorkspaceGroup = cast group;
				if (request.name != deletedGroup.name || request.parent != deletedGroup.parent || request.cwd != deletedGroup.cwd ||
					WorkspaceProtocol.order(request.order) != WorkspaceProtocol.order(deletedGroup.order)) {
					context.fail(new RpcError("stale_revision", "Group changed", false)); return;
				}
			}
			if (operationCount >= operationLimit || sequence == 0x7fffffff || (group != null && group.revision == 0x7fffffff)) {
				context.fail(new RpcError("operation_limit", "Operation retention full", false));
				return;
			}
			if (request.action == "create" && snapshot().groups.length >= 32) {
				context.fail(new RpcError("group_limit", "Workspace group limit", false)); return;
			}
			var cwd:Null<String> = request.cwd;
			// Store the machine's canonical spelling (separators, case, symlinks) of a newly chosen directory.
			// A group that keeps its directory can still be renamed or moved after that directory disappears.
			var chosen = cwd == null ? "" : cwd, resolve = resolveDirectory;
			if (chosen.length > 0 && chosen.length <= 1024 && resolve != null && (group == null || chosen != group.cwd)) {
				var resolved = resolve(chosen);
				if (resolved == null) {
					context.fail(new RpcError("invalid_directory", "Choose an existing folder", false)); return;
				}
				cwd = resolved;
			}
			var updated:WorkspaceGroup = {
				id: request.group, name: request.name,
				cwd: cwd,
				parent: request.parent,
				order: WorkspaceProtocol.order(request.order),
				revision: (group == null ? 0 : group.revision) + 1
			};
			if (!validHierarchy(updated.id, updated.parent) || WorkspaceProtocol.order(updated.order) < 0 || WorkspaceProtocol.order(updated.order) > WorkspaceProtocol.MAX_ORDER
				|| updated.cwd != null && (updated.cwd.length == 0 || updated.cwd.length > 1024)) {
				context.fail(new RpcError("invalid_group", "Invalid parent or workspace directory", false)); return;
			}
			var outcome:RenameResult = {
				epoch: epoch,
				operation: request.operation,
				sequence: sequence + 1,
				group: updated, deleted: request.action == "delete" ? true : null
			};
			if (persistence != null) {
				try
					persistence.commit(request, outcome)
				catch (_:Dynamic) {
					storageFailed = true;
					context.fail(new RpcError("storage_failed", "Workspace commit failed; reopen storage to reconcile", true));
					return;
				}
			}
			// Durable commit precedes every in-memory update and reply.

			if (outcome.deleted == true) { groups.remove(updated.id); removedGroups.set(updated.id, true); }
			else groups.set(updated.id, updated);
			sequence++;
			operationCount++;
			operations.set(request.operation, {
				request: WorkspaceProtocol.copyMutation(request),
				outcome: outcome
			});
			context.respond(WorkspaceProtocol.copyOutcome(outcome));
			prune();
		}
		connection.register(WorkspaceProtocol.GROUP, mutate);
		return function() {
			observer.granted = false;
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
