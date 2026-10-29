package ui;

import haxeon.ui.Insets;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.TextWrap;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.TextStyleOverride;
import haxeon.ui.core.View;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.controls.Button;
import haxeon.ui.widgets.controls.ButtonVariant;
import haxeon.ui.widgets.layout.Column;
import haxeon.ui.widgets.scroll.ScrollView;
import haxeon.ui.widgets.text.Text;
import workspace.client.MachineWorkspaces;

/** What the Machine view shows and does; ExosuitApp supplies it. */
typedef MachineViewActions = {
	/** The workspace manager this editor is attached to, by generation; empty when none. */
	var attachedGeneration:Void->String;
	/** Attaches to `root`'s manager on `stateDir`, opening `root` when it is not the open folder. */
	var attach:(root:String, stateDir:String, defaultState:Bool) -> Void;
	/** Starts a manager on this editor's build for `root`, from a copy of the catalog of the one on `fromState`. */
	var startOwn:(root:String, fromState:String) -> Void;
}

/**
	The Machine view: this machine and every workspace manager running on it, grouped by folder, with the build each
	runs. One machine can run several managers for one folder; this is where the editor picks which it uses.
**/
class MachinePanel implements View {
	final machine:MachineWorkspaces;
	final actions:MachineViewActions;
	final requestFrame:Void->Void;

	public function new(machine:MachineWorkspaces, actions:MachineViewActions, requestFrame:Void->Void) {
		this.machine = machine;
		this.actions = actions;
		this.requestFrame = requestFrame;
	}

	function line(value:String, context:BuildContext, secondary:Bool = false, size:Int = 13):Text {
		var style = new LayoutStyle();
		style.width = LayoutAxis.stretch();
		return new Text(value, style, secondary ? context.theme.tokens.textSecondary : context.theme.tokens.textPrimary,
			new TextStyleOverride(null, size, 0, TextWrap.WordCharacter));
	}

	function group(id:String, children:Array<KeyedView>, gap:Int):Column {
		var style = new LayoutStyle();
		style.width = LayoutAxis.stretch();
		style.childGap = gap;
		return new Column(id, children, style);
	}

	static function folderName(root:String):String {
		var path = StringTools.replace(root, "\\", "/");
		while (path.length > 1 && StringTools.endsWith(path, "/")) path = path.substr(0, path.length - 1);
		var slash = path.lastIndexOf("/");
		return slash < 0 ? path : path.substr(slash + 1);
	}

	static function since(startedAt:Null<Float>):String {
		if (startedAt == null) return "";
		var minutes = Std.int(Math.max(0, Date.now().getTime() - startedAt) / 60000);
		return minutes < 1 ? " · up under a minute" : minutes < 60 ? " · up " + minutes + " min"
			: " · up " + Std.int(minutes / 60) + " h " + (minutes % 60) + " min";
	}

	public function build(context:BuildContext):RenderNode {
		var listing = machine.listing;
		var rows:Array<KeyedView> = [];
		var name = listing == null || listing.machine.length == 0 ? "This machine" : listing.machine;
		rows.push(new KeyedView("machine", line(name + " · this machine", context, false, 15)));
		if (listing == null) rows.push(new KeyedView("loading", line(machine.error == null ? "Looking for workspaces…" : machine.error, context, true)));
		else {
			rows.push(new KeyedView("intro", line("Workspace services running here. Several can serve one folder, each on its own build and state; "
				+ "pick the one this editor uses.", context, true)));
			if (listing.managers.length == 0) rows.push(new KeyedView("empty", line("No workspace services are running.", context, true)));
			var attached = actions.attachedGeneration();
			var roots:Array<String> = [];
			for (manager in listing.managers) if (roots.indexOf(manager.root) < 0) roots.push(manager.root);
			roots.sort(function(a, b) return Reflect.compare(folderName(a).toLowerCase(), folderName(b).toLowerCase()));
			for (root in roots) rows.push(new KeyedView("root:" + root, folder(root, listing, attached, context)));
			if (machine.error != null) rows.push(new KeyedView("error", line(machine.error, context)));
		}
		var refresh = new Button("Refresh", null, function() { machine.refresh(); requestFrame(); }, "machine-refresh");
		rows.push(new KeyedView("refresh", refresh));
		var style = new LayoutStyle();
		style.width = LayoutAxis.stretch();
		style.childGap = 14;
		style.padding = new Insets(12, 12, 12, 12);
		var viewport = new LayoutStyle();
		viewport.width = LayoutAxis.stretch();
		viewport.height = LayoutAxis.grow();
		return new ScrollView("machine-scroll", new Column("machine-content", rows, style), viewport).build(context);
	}

	function folder(root:String, listing:MachineListing, attached:String, context:BuildContext):Column {
		var children:Array<KeyedView> = [
			new KeyedView("name", line(folderName(root), context)),
			new KeyedView("path", line(root, context, true, 12))
		];
		var managers = [for (manager in listing.managers) if (manager.root == root) manager];
		// The default state first: it is the one an editor finds unless told otherwise.
		managers.sort(function(a, b) return a.defaultState == b.defaultState ? a.managerPid - b.managerPid : a.defaultState ? -1 : 1);
		var own = false, source:Null<String> = null;
		for (manager in managers) {
			var current = attached.length > 0 && manager.generation == attached;
			var mine = MachineWorkspaces.normalPath(manager.launcher) == MachineWorkspaces.normalPath(listing.launcher);
			if (mine) own = true;
			if (current || source == null && manager.defaultState) source = manager.stateDir;
			var label = (current ? "● " : "○ ") + MachineWorkspaces.buildLabel(manager.launcher, listing.launcher)
				+ " · " + (manager.defaultState ? "default state" : "own state") + " · PID " + manager.managerPid + since(manager.startedAt);
			var key = "manager-" + manager.generation;
			var rowChildren:Array<KeyedView> = [new KeyedView("label", line(label, context, !current))];
			if (current) rowChildren.push(new KeyedView("attached", line("This editor uses it", context, true, 12)));
			else {
				var target = manager;
				rowChildren.push(new KeyedView("attach", new Button("Use this one", null, function() {
					actions.attach(target.root, target.stateDir, target.defaultState);
					requestFrame();
				}, "machine-attach-" + manager.generation)));
			}
			children.push(new KeyedView(key, group(key, rowChildren, 4)));
		}
		if (!own && source != null) {
			var from = source;
			var start = new Button("Start one on this editor's build", null, function() {
				actions.startOwn(root, from);
				requestFrame();
			}, "machine-start-own-" + haxe.crypto.Sha256.encode(root).substr(0, 12));
			start.variant = ButtonVariant.Primary;
			children.push(new KeyedView("start-own", start));
			children.push(new KeyedView("start-own-hint", line("Starts from a copy of its groups and sessions. The services then change independently.", context, true, 12)));
		}
		return group("machine-root-" + haxe.crypto.Sha256.encode(root).substr(0, 12), children, 8);
	}
}
