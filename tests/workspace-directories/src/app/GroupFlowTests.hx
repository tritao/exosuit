package app;

import haxeon.rpc.*;
import workspace.client.RpcWorkspaceWorkbenchClient;
import workspace.runtime.WorkspaceDirectories;
import workspace.service.WorkspaceProtocol;
import workspace.service.WorkspaceService;
import workspace.service.WorkspaceTerminalProtocol;

/**
 * The Workbench's group actions end to end through the real client and service: New group, rename, change directory
 * (outside the workspace too), inherit, move, sort order and remove, each acting on the catalog copy the menu holds.
 */
class GroupFlowTests {
	static function require(value:Bool, message:String):Void {
		if (!value) throw message;
	}

	public static function run(directories:WorkspaceDirectories, outside:String):Void {
		var root = directories.root, now = 1000.0;
		var clock = function() return now;
		var service = new WorkspaceService("workspace", "epoch", [{id: "work", name: "Work", cwd: root, revision: 1}], 32, 256, 16, null,
			directories.resolve);
		var pair = MemoryTransport.pair(), connection = new RpcConnection(pair.client, clock), server = new RpcConnection(pair.server, clock);
		service.bind(server, [WorkspaceProtocol.READ, WorkspaceProtocol.WRITE, WorkspaceProtocol.TREE, WorkspaceProtocol.REMOVE,
			WorkspaceProtocol.EVENTS]);
		service.canRemoveGroup = function(_) return true;
		// The terminal manager's catalog carries the service's groups; no terminals are needed here.
		server.register(WorkspaceTerminalProtocol.LIST, function(_, context) context.respond({instance: "owner", workspaceRoot: root,
			next: null, terminals: [], groups: service.snapshot().groups}));
		var client = new RpcWorkspaceWorkbenchClient(new FlowEndpoint(connection, root), clock);
		function pump():Void for (_ in 0...6) { client.poll(); server.poll(); connection.poll(); now += 1; }
		function settle():Void {
			for (_ in 0...20) { pump(); client.refreshTerminals(false); now += 1100; }
			pump();
			require(!client.terminalCatalogBusy(), "Catalog mutation never finished");
		}
		function current():WorkspaceTerminalProtocol.TerminalCatalog {
			require(client.terminalCatalog() != null, "No catalog");
			return cast client.terminalCatalog();
		}
		function group(id:String):WorkspaceGroup {
			var catalog = current();
			for (candidate in catalog.groups) if (candidate.id == id) return candidate;
			throw "Group " + id + " missing from the catalog";
		}
		function change(id:String, name:String, parent:Null<String>, cwd:Null<String>, order:Int, create:Bool, step:String):WorkspaceGroup {
			var catalog = current();
			require(client.canEditGroups() && !client.terminalCatalogBusy(), step + ": group editing unavailable");
			var base:WorkspaceGroup = create ? {id: id, name: "", cwd: null, revision: 0, parent: parent, order: order} : group(id);
			client.changeGroup(catalog.instance, base, name, parent, cwd, order, create);
			require(client.terminalCatalogBusy(), step + ": the request was not sent");
			settle();
			require(client.terminalCatalogError() == null, step + " failed: " + client.terminalCatalogError());
			var updated = group(id);
			require(updated.revision == base.revision + 1 && updated.name == name && updated.parent == parent, step + ": catalog did not follow");
			return updated;
		}
		client.refreshTerminals(true);
		settle();
		require(client.terminalCatalog() != null, "Catalog never loaded");

		change("fresh", "New group", null, null, 1, true, "New group");
		change("fresh", "resume-2026", null, null, 1, false, "Rename");
		var moved = change("fresh", "resume-2026", null, outside, 1, false, "Change Working Directory outside the workspace");
		require(moved.cwd == directories.resolve(outside) && moved.cwd != null, "Outside directory was not stored: " + moved.cwd);
		change("child", "Drafts", "fresh", null, 0, true, "New sub-group");
		require(directories.forGroup(service.snapshot().groups, "child") == moved.cwd, "Sub-group did not inherit the outside folder");
		var own = change("child", "Drafts", "fresh", root, 0, false, "Sub-group with its own folder");
		require(directories.forGroup(service.snapshot().groups, "child") == own.cwd, "Sub-group folder was not used");
		change("fresh", "resume-2026", null, null, 1, false, "Use Inherited Working Directory");
		require(directories.forGroup(service.snapshot().groups, "fresh") == root, "Inherited group did not fall back to the root");
		change("fresh", "resume-2026", "work", null, 1, false, "Move to Group");
		change("fresh", "resume-2026", "work", null, 7, false, "Change Sort Order");
		require(group("fresh").order == 7, "Sort order was not stored");

		client.removeGroup(current().instance, group("child"));
		settle();
		require(client.terminalCatalogError() == null, "Remove failed: " + client.terminalCatalogError());
		require(!Lambda.exists(current().groups, function(g) return g.id == "child"), "Removed group stayed in the catalog");

		// A rejected directory reports the reason and leaves the group editable.
		var before = group("fresh");
		client.changeGroup(current().instance, before, before.name, before.parent, root + "/missing-folder", 7, false);
		settle();
		var error = client.terminalCatalogError();
		require(error != null && error.indexOf("existing folder") >= 0, "Missing folder error was not reported: " + error);
		require(group("fresh").revision == before.revision, "Rejected change altered the group");
		change("fresh", "resume-2026", "work", null, 8, false, "Edit after a rejected change");
	}
}

private class FlowEndpoint implements workspace.client.WorkspaceRpcEndpoint {
	final connection:RpcConnection;
	final root:String;

	public function new(connection:RpcConnection, root:String) {
		this.connection = connection;
		this.root = root;
	}

	public function rootPath():Null<String> return root;
	public function serviceGeneration():String return "owner";
	public function terminalEvents():Null<workspace.client.WorkspaceTerminalEvents> return null;
	public function rpcConnection():Null<RpcConnection> return connection;
	public function failureReason():Null<String> return null;
	public function supportsWorkspaceGroups():Bool return true;
	public function workspaceEpoch():Null<String> return "epoch";
	public function hasCapability(capability:String):Bool return true;
}
