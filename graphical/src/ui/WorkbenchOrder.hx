package ui;

import workspace.service.WorkspaceAgentProtocol.AgentCatalog;
import workspace.service.WorkspaceProtocol;
import workspace.service.WorkspaceTerminalProtocol.TerminalCatalog;

/** One write that puts a row at `order` in `group` (the workspace root for ROOT_GROUP). */
typedef PlaceStep = {
	var key:String;
	var group:String;
	var order:Int;
}

/** Where a drop between rows lands, and the writes that make it so; `refusal` is set instead of steps when the client may not make them. */
typedef Placement = {
	/** The row the dropped rows go before or after; an expanded group's lower edge is its first child's upper edge. */
	var anchor:String;
	var after:Bool;
	var steps:Array<PlaceStep>;
	/** Selected rows that cannot go there, and so stay put. */
	var skipped:Int;
	/** Why the drop is refused, when its writes include rows this client may not change; the steps are then empty. */
	var refusal:Null<String>;
}

/**
	Re-ordering policy: pure functions of the tree model and the current catalogs, evaluated at release as well as while
	dragging. Positions are spaced `STEP` apart, so a move writes only the moved rows, at the middle between their new
	neighbours. Siblings are renumbered with that spacing only when no gap is left there, or a neighbour has no position
	yet, and then only the rows whose group or number changes are written. Only rows the client may write are planned;
	a placement that needs another write is refused.
**/
class WorkbenchOrder {
	/** The distance between neighbouring positions after a renumbering, and the room appended rows are given. */
	public static inline final STEP = 1024;

	/** `siblings` with `moving` (in the order given) taken out and put before or after `anchor`, which is not among them. */
	public static function sequence(siblings:Array<String>, moving:Array<String>, anchor:String, after:Bool):Array<String> {
		var rest = siblings.filter(function(key) return moving.indexOf(key) < 0);
		var at = rest.indexOf(anchor);
		if (at < 0) at = rest.length;
		else if (after) at++;
		return rest.slice(0, at).concat(moving).concat(rest.slice(at));
	}

	/**
		The placement that puts `keys` before or after `anchor`, in the anchor's group; null when nothing can go there or
		every row is already in place. Rows that cannot move (a session of another workspace, a group into its own
		contents) are left out and counted in `skipped`.
	**/
	public static function plan(model:WorkbenchTreeModel, catalog:TerminalCatalog, agents:Null<AgentCatalog>, keys:Array<String>, anchor:String,
			after:Bool, writable:String->Bool):Null<Placement> {
		var destination = model.groupOfRow(anchor);
		if (destination == null || !WorkspaceProtocol.knownGroup(destination, catalog.groups)) return null;
		var parent = WorkspaceProtocol.parentFor(destination), moving:Array<String> = [];
		for (key in keys) {
			if (key == anchor || moving.indexOf(key) >= 0) continue;
			if (writable(key) && canPlace(model, catalog, agents, key, destination, parent)) moving.push(key);
		}
		var skipped = Lambda.count(keys, function(key) return key != anchor) - moving.length;
		if (moving.length == 0) return null;
		var current = model.siblings(destination);
		var shown = sequence(current, moving, anchor, after);
		var first = shown.indexOf(moving[0]);
		var left = first > 0 ? shown[first - 1] : null, right = first + moving.length < shown.length ? shown[first + moving.length] : null;
		var steps:Array<PlaceStep> = [];
		var targets = gap(model, left, right, moving.length);
		if (targets != null) {
			if (inPlace(model, destination, moving, current, shown, left, right)) return null;
			for (index in 0...moving.length) {
				var key = moving[index];
				if (model.groupOfRow(key) != destination || model.orderOfRow(key) != targets[index]) steps.push({key: key, group: destination, order: targets[index]});
			}
		} else {
			// No room between the neighbours, or one has no position: number every sibling with room again.
			var step = Std.int(Math.max(1, Math.min(STEP, WorkspaceProtocol.MAX_ORDER / Math.max(1, shown.length))));
			for (index in 0...shown.length) {
				var key = shown[index], order = index * step;
				if (model.groupOfRow(key) != destination || model.orderOfRow(key) != order) steps.push({key: key, group: destination, order: order});
			}
		}
		if (steps.length == 0) return null;
		var blocked = steps.filter(function(step) return !writable(step.key)).length;
		if (blocked > 0)
			return {anchor: anchor, after: after, steps: [], skipped: skipped,
				refusal: "That place needs " + blocked + " other " + (blocked == 1 ? "row" : "rows") + " renumbered, which you can't change"};
		return {anchor: anchor, after: after, steps: steps, skipped: skipped, refusal: null};
	}

	/**
		`count` positions that sort between `left` and `right` (rows beside the moved ones, null at an end), spread evenly; null when
		there is no room, or `left` has no position (rows without one sort after every row with one).
	**/
	static function gap(model:WorkbenchTreeModel, left:Null<String>, right:Null<String>, count:Int):Null<Array<Int>> {
		var low:Null<Int> = left == null ? null : model.orderOfRow(left), high:Null<Int> = right == null ? null : model.orderOfRow(right);
		if (left != null && low == null) return null;
		if (high != null) {
			var from:Int = low == null ? -1 : low, room:Int = high - from;
			if (room < count + 1) return null;
			return [for (index in 0...count) from + Std.int(room / (count + 1) * (index + 1))];
		}
		var start:Int = low == null ? -STEP : low, last = start + STEP * count;
		if (last > WorkspaceProtocol.MAX_ORDER) return null;
		return [for (index in 0...count) start + STEP * (index + 1)];
	}

	/** Whether dropping already leaves the rows where they sort: the same sequence, their positions between the neighbours', in order. */
	static function inPlace(model:WorkbenchTreeModel, destination:String, moving:Array<String>, current:Array<String>, shown:Array<String>,
			left:Null<String>, right:Null<String>):Bool {
		if (current.join(",") != shown.join(",")) return false;
		var low:Null<Int> = left == null ? null : model.orderOfRow(left), high:Null<Int> = right == null ? null : model.orderOfRow(right);
		var previous:Int = left == null ? -1 : low == null ? -1 : low;
		for (key in moving) {
			var order = model.orderOfRow(key);
			if (model.groupOfRow(key) != destination) return false;
			if (order == null) {
				// A row without a position sorts after every placed one, so it is in place only among such rows.
				if (left != null && low != null && right != null && high != null) return false;
				continue;
			}
			if (order <= previous || (high != null && order >= high)) return false;
			previous = order;
		}
		return true;
	}

	static function canPlace(model:WorkbenchTreeModel, catalog:TerminalCatalog, agents:Null<AgentCatalog>, key:String, destination:String,
			parent:Null<String>):Bool {
		var row = WorkbenchRowKey.parse(key);
		if (row == null || model.groupOfRow(key) == null) return false;
		return switch row.kind {
			case WorkbenchRowKind.Group:
				var group = model.groups.get(row.id);
				group != null && (group.parent == parent || GroupContextActions.canParent(row.id, parent, catalog.groups));
			case WorkbenchRowKind.Terminal: true;
			case WorkbenchRowKind.Agent: agents != null && agents.instance == catalog.instance && agents.root == catalog.workspaceRoot;
		};
	}
}
