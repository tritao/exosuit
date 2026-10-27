package ui;

import haxe.io.Bytes;
import haxeon.ui.LayoutAlignmentY;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.Insets;
import haxeon.ui.TextAlignment;
import haxeon.ui.TextWrap;
import haxeon.ui.core.View;
import haxeon.ui.widgets.collections.TreeRootMetadata;
import haxeon.ui.widgets.collections.TreeViewModel;
import haxeon.ui.widgets.layout.Row;
import haxeon.ui.widgets.layout.SizedBox;
import haxeon.ui.widgets.text.MiddleEllipsisText;
import haxeon.ui.widgets.text.Text;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.Icon;
import haxeon.ui.icons.IconName;
import haxeon.ui.widgets.overlays.Tooltip;
import haxeon.ui.widgets.controls.Button;
import haxeon.ui.core.TextStyleOverride;
import haxeon.ui.theme.Theme;
import scm.ScmGroup;
import scm.ScmGroupId;
import scm.ScmRepository;
import scm.ScmResource;
import scm.ScmSnapshot;
import scm.ScmSource;

/** Snapshot-backed hierarchy shared by the local and RPC source-control view. */
class ScmTreeModel implements TreeViewModel {
	static inline final ROW_HEIGHT = 28.0;
	final source:ScmSource;
	final theme:Theme;
	final changed:Void->Void;
	final mutationAction:(ScmRepository, Null<ScmGroup>, Null<ScmResource>)->Void;
	final trustAction:ScmRepository->Void;
	final cancelSubscription:Void->Void;
	var repositories:Array<ScmRepository> = [];
	var roots:Array<ScmRepository> = [];
	final repositoryByKey:Map<String, ScmRepository> = [];
	final groupByKey:Map<String, ScmTreeGroup> = [];
	final resourceByKey:Map<String, ScmTreeResource> = [];
	final children:Map<String, Array<String>> = [];
	var revisionValue:Int = 0;
	var rootErrorValue:Null<String>;
	var loading:Bool = false;
	var disposed:Bool = false;

	public function new(source:ScmSource, theme:Theme, changed:Void->Void,
		?mutationAction:(ScmRepository, Null<ScmGroup>, Null<ScmResource>)->Void, ?trustAction:ScmRepository->Void) {
		if (source == null || theme == null || changed == null) throw "Invalid source-control tree model";
		this.source = source;
		this.theme = theme;
		this.changed = changed;
		this.mutationAction = mutationAction;
		this.trustAction = trustAction;
		cancelSubscription = source.subscribe(function(_, _) refreshData());
		refreshData();
		discover();
	}

	public var rootError(get, never):Null<String>;
	function get_rootError():Null<String> return rootErrorValue;
	public var isLoading(get, never):Bool;
	function get_isLoading():Bool return loading;
	public function repositoriesSnapshot():Array<ScmRepository> return repositories.copy();
	public function snapshot(repositoryId:String):Null<ScmSnapshot> return source.snapshot(repositoryId);
	public function error(repositoryId:String):Null<scm.ScmError> return source.error(repositoryId);
	public function connected():Bool return source.connected();
	public function remote():Bool return source.isRemote();
	public function sourceIdentity():String return source.identity();

	public function refresh():Void {
		if (disposed) return;
		source.poll();
		for (repository in repositories) source.refreshNow(repository.id);
		discover();
	}

	public function trust(repositoryId:String, complete:Bool->Null<scm.ScmError>->Void):Void {
		if (disposed) return;
		source.trust(repositoryId, function(result) {
			if (result.error == null && result.value == true) source.refreshNow(repositoryId);
			else if (result.error == null) complete(false, new scm.ScmError("trust_failed", "Could not trust this repository"));
			else complete(false, result.error);
			if (result.error == null && result.value == true) complete(true, null);
		});
	}

	public function dispose():Void {
		if (disposed) return;
		disposed = true;
		cancelSubscription();
	}

	public function rootCount():Int return roots.length;
	public function rootRange(start:Int, count:Int):Array<TreeRootMetadata> {
		var result:Array<TreeRootMetadata> = [];
		if (start < 0 || count <= 0) return result;
		var end = Std.int(Math.min(roots.length, start + count));
		for (index in start...end) result.push(new TreeRootMetadata(repositoryKey(roots[index]), true));
		return result;
	}
	public function rootKeyAt(index:Int):String return index >= 0 && index < roots.length ? repositoryKey(roots[index]) : "";
	public function childCount(parentKey:String):Int {
		var values = children.get(parentKey);
		return values == null ? 0 : values.length;
	}
	public function childKeyAt(parentKey:String, index:Int):String {
		var values = children.get(parentKey);
		return values == null || index < 0 || index >= values.length ? "" : values[index];
	}
	public function initiallyExpanded(key:String):Bool return StringTools.startsWith(key, "repo:");
	public function estimatedExtent():Float return ROW_HEIGHT;
	public function extentIsUniform():Bool return true;
	public function extentAt(key:String):Float return ROW_HEIGHT;
	public function revision():Int return revisionValue;

	public function buildItem(key:String):View {
		var style = new LayoutStyle();
		style.width = LayoutAxis.grow();
		style.height = LayoutAxis.fixed(ROW_HEIGHT);
		style.childAlignY = LayoutAlignmentY.Center;
		style.childGap = 5.0;
		// Let the row compress its filename box; clipping the row disables that
		// compression in the layout engine and lets long names displace actions.
		// The tree's overlay scrollbar owns the last 12 pixels of the viewport.
		style.padding = new Insets(0.0, 0.0, 16.0, 0.0);
		var children:Array<KeyedView> = [];
		var actionChildren:Array<KeyedView> = [];
		var syncChildren:Array<KeyedView> = [];
		var foreground = theme.tokens.text;
		var label = "";
		var badge = "";
		var badgeColor = theme.tokens.textSecondary;
		var detail = "";
		var repo = repositoryByKey.get(key);
		if (repo != null) {
			var head = source.snapshot(repo.id);
			label = repositoryName(repo.root);
			if (head != null && head.head.branch != null) detail = head.head.branch;
			else if (head != null && head.head.detachedCommit != null) detail = "detached " + head.head.detachedCommit.substr(0, 8);
			if (head != null && head.head.upstream != null) {
				for (direction in ["ahead", "behind"]) {
					var count = direction == "ahead" ? head.head.ahead : head.head.behind;
					if (count <= 0) continue;
					var description = count + (count == 1 ? " commit " : " commits ") + direction
						+ (direction == "ahead" ? " of " : " ") + head.head.upstream;
					var counter = new ScmSyncCount(direction, count, description, theme.tokens.textSecondary);
					syncChildren.push(new KeyedView(direction, new Tooltip("sync-" + direction, counter, new Text(description), 0.0, 28.0)));
				}
			}
			if (head != null && head.head.operation != null) detail += (detail.length > 0 ? "  " : "") + operationLabel(head.head.operation);
			if (!repo.trusted) {
				var statusStyle = new LayoutStyle();
				statusStyle.width = LayoutAxis.fixed(68.0);
				actionChildren.push(new KeyedView("trust-status", new Text("Restricted", statusStyle,
					theme.tokens.warning, TextStyleOverride.text(12.0))));
				if (!source.isRemote() && trustAction != null) {
					var trustStyle = new LayoutStyle();
					trustStyle.width = LayoutAxis.fixed(58.0);
					trustStyle.height = LayoutAxis.fixed(22.0);
					var trust = new Button("Trust", trustStyle, function() trustAction(repo), "scm-trust:" + repo.id);
					trust.variant = haxeon.ui.widgets.controls.ButtonVariant.Secondary;
					trust.accessibilityLabel = "Trust repository " + repo.root;
					actionChildren.push(new KeyedView("trust-action", trust));
				}
			}
			if (mutationAction != null && source.canWrite(repo.id) && head != null &&
				(hasGroupResources(head, [ScmGroupId.WorkingTree, ScmGroupId.Untracked]) || hasGroupResources(head, [ScmGroupId.Index]))) {
				var stage = hasGroupResources(head, [ScmGroupId.WorkingTree, ScmGroupId.Untracked]);
				actionChildren.push(mutationButton("repo-mutation", stage ? "Stage" : "Unstage", stage ? "Stage all changes" : "Unstage all changes",
					function() mutationAction(repo, null, null)));
			}
		} else {
			var group = groupByKey.get(key);
			if (group != null) {
				label = groupLabel(group.group.id);
				badge = Std.string(group.group.resources.length);
				badgeColor = theme.tokens.textSecondary;
				if (mutationAction != null && source.canWrite(group.repository.id) && group.group.resources.length > 0 &&
					(group.group.id == ScmGroupId.WorkingTree || group.group.id == ScmGroupId.Untracked || group.group.id == ScmGroupId.Index)) {
					var stage = group.group.id != ScmGroupId.Index;
					actionChildren.push(mutationButton("group-mutation", stage ? "Stage" : "Unstage", (stage ? "Stage " : "Unstage ") + label.toLowerCase(),
						function() mutationAction(group.repository, group.group, null)));
				}
			} else {
				var resource = resourceByKey.get(key);
				if (resource != null) {
					label = resource.resource.path;
					if (resource.resource.originalPath != null) detail = resource.resource.originalPath + " → ";
					badge = statusBadge(resource.resource);
					badgeColor = resource.resource.conflictKind == null ? theme.tokens.warning : theme.tokens.danger;
					if (mutationAction != null && source.canWrite(resource.repository.id) &&
						(resource.group.id == ScmGroupId.WorkingTree || resource.group.id == ScmGroupId.Untracked || resource.group.id == ScmGroupId.Index)) {
						var stage = resource.group.id != ScmGroupId.Index;
						actionChildren.push(mutationButton("file-mutation", stage ? "Stage" : "Unstage", (stage ? "Stage " : "Unstage ") + resource.resource.path,
							function() mutationAction(resource.repository, resource.group, resource.resource)));
					}
				}
			}
		}
		var textStyle = new TextStyleOverride(null, 13.0, null, TextWrap.None, null, null, null, foreground);
		if (repo == null && detail.length > 0) label = detail + label;
		// A no-wrap text node cannot shrink along a row's main axis. Give it a
		// bounded box so ellipsis leaves room for the fixed status/action columns.
		var labelBox = new SizedBox("label-box", new MiddleEllipsisText("label", label, true, textStyle));
		labelBox.style.clipHorizontal = true;
		children.push(new KeyedView("label", labelBox));
		if (repo != null && detail.length > 0) {
			var branch = new SizedBox("branch-box", new MiddleEllipsisText("branch", detail, true,
				new TextStyleOverride(null, 12.0, null, TextWrap.None, null, null, null, theme.tokens.textSecondary)));
			branch.style.width = LayoutAxis.grow(0.0, 120.0);
			branch.style.clipHorizontal = true;
			children.push(new KeyedView("branch", branch));
		}
		for (counter in syncChildren) children.push(counter);
		if (badge.length > 0) {
			var badgeStyle = new LayoutStyle();
			badgeStyle.width = LayoutAxis.fixed(24.0);
			children.push(new KeyedView("badge", new Text(badge, badgeStyle, badgeColor,
				new TextStyleOverride(null, 12.0, null, TextWrap.None, TextAlignment.Center))));
		}
		for (action in actionChildren) children.push(action);
		return new Row("scm-tree-row", children, style);
	}

	function mutationButton(key:String, label:String, description:String, action:Void->Void):KeyedView {
		var buttonStyle = new LayoutStyle();
		buttonStyle.width = LayoutAxis.fixed(64.0);
		buttonStyle.height = LayoutAxis.fixed(22.0);
		buttonStyle.padding = new Insets(4.0, 0.0, 4.0, 0.0);
		var button = new Button(label, buttonStyle, action, "scm-row-action:" + key);
		button.accessibilityLabel = description;
		return new KeyedView(key, button);
	}

	static function hasGroupResources(snapshot:ScmSnapshot, ids:Array<ScmGroupId>):Bool {
		for (group in snapshot.groups) if (ids.indexOf(group.id) >= 0 && group.resources.length > 0) return true;
		return false;
	}

	public function repositoryForKey(key:String):Null<ScmRepository> {
		var repo = repositoryByKey.get(key);
		if (repo != null) return repo;
		var group = groupByKey.get(key);
		if (group != null) return group.repository;
		var resource = resourceByKey.get(key);
		return resource == null ? null : resource.repository;
	}
	public function groupForKey(key:String):Null<ScmGroup> {
		var group = groupByKey.get(key);
		if (group != null) return group.group;
		var resource = resourceByKey.get(key);
		return resource == null ? null : resource.group;
	}
	public function resourceForKey(key:String):Null<ScmResource> {
		var value = resourceByKey.get(key);
		return value == null ? null : value.resource;
	}

	function discover():Void {
		if (disposed || loading) return;
		loading = true;
		rootErrorValue = null;
		source.discover(function(result) {
			if (disposed) return;
			loading = false;
			if (result.error != null) rootErrorValue = result.error.message;
			refreshData();
		});
	}

	function refreshData():Void {
		if (disposed) return;
		repositories = source.repositories();
		var known:Map<String, Bool> = [];
		for (repository in repositories) known.set(repository.id, true);
		roots = [for (repository in repositories) if (repository.parentId == null || !known.exists(repository.parentId)) repository];
		repositoryByKey.clear(); groupByKey.clear(); resourceByKey.clear(); children.clear();
		for (repository in repositories) {
			var key = repositoryKey(repository);
			repositoryByKey.set(key, repository);
			var snapshot = source.snapshot(repository.id);
			if (snapshot != null) for (group in snapshot.groups) {
				var groupKey = groupKeyFor(repository, group);
				groupByKey.set(groupKey, new ScmTreeGroup(repository, group));
				var groupChildren:Array<String> = [];
				for (resource in group.resources) {
					var resourceKey = resourceKeyFor(repository, group, resource);
					resourceByKey.set(resourceKey, new ScmTreeResource(repository, group, resource));
					groupChildren.push(resourceKey);
				}
				children.set(groupKey, groupChildren);
			}
		}
		for (repository in repositories) {
			var parent = repository.parentId == null ? null : findRepository(repository.parentId);
			if (parent != null) appendChild(repositoryKey(parent), repositoryKey(repository));
		}
		for (repository in repositories) {
			var key = repositoryKey(repository), snapshot = source.snapshot(repository.id);
			if (snapshot != null) for (group in snapshot.groups) appendChild(key, groupKeyFor(repository, group));
		}
		revisionValue++;
		changed();
	}

	function appendChild(parent:String, child:String):Void {
		var values = children.get(parent);
		if (values == null) { values = []; children.set(parent, values); }
		values.push(child);
	}
	function findRepository(id:String):Null<ScmRepository> {
		for (repository in repositories) if (repository.id == id) return repository;
		return null;
	}
	static function repositoryKey(repository:ScmRepository):String return "repo:" + repository.id.length + ":" + repository.id;
	static function groupKeyFor(repository:ScmRepository, group:ScmGroup):String
		return "group:" + repository.id.length + ":" + repository.id + ":" + group.id;
	static function resourceKeyFor(repository:ScmRepository, group:ScmGroup, resource:ScmResource):String
		return "file:" + repository.id.length + ":" + repository.id + ":" + group.id + ":" + resource.pathBytes.length + ":" + resource.path;
	static function repositoryName(path:String):String {
		var normalized = StringTools.replace(path, "\\", "/"), end = normalized.length;
		while (end > 1 && StringTools.endsWith(normalized, "/")) { normalized = normalized.substr(0, normalized.length - 1); end--; }
		var slash = normalized.lastIndexOf("/");
		return slash < 0 ? normalized : normalized.substr(slash + 1);
	}
	static function groupLabel(id:ScmGroupId):String
		return id == ScmGroupId.Merge ? "Merge Changes" : id == ScmGroupId.Index ? "Staged Changes" :
			id == ScmGroupId.WorkingTree ? "Changes" : id == ScmGroupId.Untracked ? "Untracked" : Std.string(id);
	static function statusBadge(resource:ScmResource):String {
		if (resource.conflictKind != null || resource.changeKind == scm.ScmChangeKind.Unmerged) return "!";
		return resource.changeKind == scm.ScmChangeKind.Added || resource.changeKind == scm.ScmChangeKind.Untracked ? "A" :
			resource.changeKind == scm.ScmChangeKind.Modified ? "M" : resource.changeKind == scm.ScmChangeKind.Deleted ? "D" :
			resource.changeKind == scm.ScmChangeKind.Renamed ? "R" : resource.changeKind == scm.ScmChangeKind.Copied ? "C" :
			resource.changeKind == scm.ScmChangeKind.TypeChanged ? "T" : resource.changeKind == scm.ScmChangeKind.Ignored ? "I" : "?";
	}
	static function operationLabel(operation:scm.ScmHeadOperation):String
		return operation == scm.ScmHeadOperation.Merge ? "Merge" : operation == scm.ScmHeadOperation.Rebase ? "Rebase" :
			operation == scm.ScmHeadOperation.CherryPick ? "Cherry-pick" : operation == scm.ScmHeadOperation.Revert ? "Revert" :
			operation == scm.ScmHeadOperation.Bisect ? "Bisect" : "";
}

private class ScmTreeGroup {
	public final repository:ScmRepository;
	public final group:ScmGroup;
	public function new(repository:ScmRepository, group:ScmGroup) { this.repository = repository; this.group = group; }
}

private class ScmTreeResource {
	public final repository:ScmRepository;
	public final group:ScmGroup;
	public final resource:ScmResource;
	public function new(repository:ScmRepository, group:ScmGroup, resource:ScmResource) {
		this.repository = repository; this.group = group; this.resource = resource;
	}
}

/** Vector direction indicators and explicit accessible descriptions, independent of font coverage. */
private class ScmSyncCount implements View {
  final direction:String;
  final count:Int;
  final description:String;
  final color:haxeon.ui.Color;
  public function new(direction:String, count:Int, description:String, color:haxeon.ui.Color) {
    this.direction = direction;
    this.count = count;
    this.description = description;
    this.color = color;
  }
  public function build(context:haxeon.ui.core.BuildContext):haxeon.ui.core.RenderNode {
    var style = new LayoutStyle();
    style.width = LayoutAxis.fit();
    style.height = LayoutAxis.fixed(22.0);
    style.childAlignY = LayoutAlignmentY.Center;
    style.childGap = 3.0;
    style.padding = new Insets(3.0, 0.0, 3.0, 0.0);
    var node = new Row("scm-sync-count", [
      new KeyedView("direction", new Icon("arrow", direction == "ahead" ? IconName.ArrowUp : IconName.ArrowDown, 14.0, color)),
      new KeyedView("count", new Text(Std.string(count), null, color, TextStyleOverride.text(12.0)))
    ], style).build(context);
    for (child in node.children) child.semantics = null;
    node.semantics = new haxeon.ui.semantics.Semantics(haxeon.ui.semantics.AccessibilityRole.Text, description);
    return node;
  }
}
