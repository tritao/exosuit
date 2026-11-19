package ui;

import workspace.client.SessionIndexSource;
import workspace.sessions.SessionIndex;

/**
	The session index of a Workbench machine, built from the catalogs the window already holds: the same path on the
	desktop (ExohostWorkbenchMachine) and on a paired phone (DeviceWorkbenchMachine). A running workspace without a link
	gets one for reading (WorkbenchMachine.readLink: as an expanded tree row's, never starting a service), marked used on
	every call so it stays while the index is read and closes WorkspaceLinks.LINGER_MS after; an idle one is read from
	its snapshot where there is one. Call it as often as needed: the index changes (`revision`) only when a catalog does.
**/
class WorkbenchSessions {
	public static function of(machine:WorkbenchMachine, source:SessionIndexSource):SessionIndex {
		var view = machine.view();
		var state = view.machine;
		if (state == null)
			return source.index;
		var watched = view.watched;
		for (entry in state.workspaces) {
			var known = watched == null ? null : watched.get(entry.id);
			if (known != null && known.running)
				machine.readLink(entry);
		}
		return source.refresh(state.id, [for (entry in state.workspaces) {id: entry.id, name: entry.name}], function(id) {
			var link = machine.linkOf(id);
			var mirror = link == null ? null : link.catalogMirror();
			if (mirror != null)
				return mirror;
			var known = watched == null ? null : watched.get(id);
			return known == null ? null : known.catalog;
		});
	}
}
