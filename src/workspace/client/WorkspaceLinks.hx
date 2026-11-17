package workspace.client;

import haxeon.platform.event.EventPump;
import workspace.client.OpenedService.ServiceOpener;

/**
	The window's links, one per workspace in use (WorkspaceLink): the workspace the window shows, a workspace whose
	running service shows rows in the expanded tree, a workspace with terminals open here. Each poll the window says
	which it uses (`use`); a link not used for LINGER_MS is closed, so a collapsed workspace holds no connection and an
	unused service can idle out. Switching the window between workspaces is a change of focus between links that stay
	connected.

	`keep` in `use` says the window needs the service itself (it shows the workspace, or has its terminals): only such
	a link asks exohost again when its service stops, which starts a new one. A link kept only for rows ends with its
	service instead.
**/
class WorkspaceLinks {
	/** How long a link stays after its last use: a row collapsed and expanded again, or a quick switch back, reuses it. */
	public static inline final LINGER_MS = 30000.0;

	final events:EventPump;
	final clock:Void->Float;
	final open:ServiceOpener;
	final links:Map<String, WorkspaceLink> = [];
	final usedAt:Map<String, Float> = [];
	final keptAt:Map<String, Float> = [];
	/** The link of a window with no workspace: it never connects. */
	public final none:WorkspaceLink;
	/** Changes whenever a link is made or closed. */
	public var revision(default, null):Int = 0;
	var disposed = false;

	public function new(events:EventPump, clock:Void->Float, open:ServiceOpener) {
		this.events = events;
		this.clock = clock;
		this.open = open;
		none = new WorkspaceLink(events, clock, open, null);
	}

	/** The link of workspace `id`, if the window holds one. */
	public function get(id:String):Null<WorkspaceLink>
		return links.get(id);

	/**
		The link of `target`'s workspace, made when there is none, and marked used now. `keep`: the window needs the
		service itself, so the link starts it again if it stops.
	**/
	public function use(target:WorkspaceServiceTarget, keep:Bool):WorkspaceLink {
		var id = target.workspace, now = clock();
		var link = links.get(id);
		if (link != null && link.ended) {
			close(id);
			link = null;
		}
		// Marked before a new link asks for its service, so the opener sees it is kept (`kept`).
		if (keep)
			keptAt.set(id, now);
		if (link == null) {
			link = new WorkspaceLink(events, clock, open, target);
			link.revive = function() return keptRecently(id, clock());
			links.set(id, link);
			revision++;
		} else
			link.follow(target);
		usedAt.set(id, now);
		return link;
	}

	/** Whether the window needed workspace `id`'s service itself within LINGER_MS (`keep` in `use`). */
	public function kept(id:String):Bool
		return keptRecently(id, clock());

	/** Marks the link of `id` used now, if there is one; false when there is none. */
	public function touch(id:String):Bool {
		if (!links.exists(id)) return false;
		usedAt.set(id, clock());
		return true;
	}

	function keptRecently(id:String, now:Float):Bool {
		var at = keptAt.get(id);
		return at != null && now - at < LINGER_MS;
	}

	public function poll():Void {
		if (disposed) return;
		none.poll();
		var now = clock();
		for (id in [for (key in links.keys()) key]) {
			var link = links.get(id), at = usedAt.get(id);
			if (link.ended || at == null || now - at >= LINGER_MS) {
				close(id);
				continue;
			}
			link.poll();
		}
	}

	function close(id:String):Void {
		var link = links.get(id);
		links.remove(id);
		usedAt.remove(id);
		keptAt.remove(id);
		if (link != null) {
			link.dispose();
			revision++;
		}
	}

	/** The links held now, `none` aside. */
	public function count():Int
		return Lambda.count(links);

	/** The workspaces with a link now. */
	public function ids():Array<String>
		return [for (id in links.keys()) id];

	public function dispose():Void {
		if (disposed) return;
		disposed = true;
		for (id in [for (key in links.keys()) key])
			close(id);
		none.dispose();
	}
}
