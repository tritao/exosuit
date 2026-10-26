package ui;

import haxeon.ui.Insets;
import haxeon.ui.LayoutAlignmentY;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.TextWrap;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.TextStyleOverride;
import haxeon.ui.core.UiEvent;
import haxeon.ui.core.View;
import haxeon.ui.theme.Theme;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.collections.TreeView;
import haxeon.ui.widgets.controls.Button;
import haxeon.ui.widgets.controls.ButtonVariant;
import haxeon.ui.widgets.layout.Column;
import haxeon.ui.widgets.layout.Row;
import haxeon.ui.widgets.scroll.ScrollController;
import haxeon.ui.widgets.text.Text;
import haxeon.ui.widgets.text.TextArea;
import scm.ScmGroup;
import scm.ScmRepository;
import scm.ScmResource;
import scm.ScmSource;

/** Read-only repository and change-list surface; actions are supplied by ExosuitApp. */
class SourceControlPanel implements View {
	final source:ScmSource;
	final theme:Theme;
	final changed:Void->Void;
	final openResource:(ScmRepository, ScmGroup, ScmResource)->Void;
	final openFile:Null<(ScmRepository, ScmGroup, ScmResource)->Void>;
	final contextMenu:(ScmRepository, ScmGroup, ScmResource, UiEvent)->Void;
	final repositoryContextMenu:(ScmRepository, Null<ScmGroup>, UiEvent)->Void;
	final retryAction:Void->Void;
	final trustAction:ScmRepository->Void;
	final commitRepository:Void->Null<ScmRepository>;
	final commitDraft:ScmRepository->String;
	final changeCommitDraft:(ScmRepository, String)->Void;
	final commitAction:(ScmRepository, Bool, Bool)->Void;
	final canCommit:ScmRepository->Bool;
	final commitMenu:(ScmRepository, UiEvent)->Void;
	final model:ScmTreeModel;
	var disposed:Bool = false;

	public function new(source:ScmSource, theme:Theme, changed:Void->Void,
		openResource:(ScmRepository, ScmGroup, ScmResource)->Void,
		contextMenu:(ScmRepository, ScmGroup, ScmResource, UiEvent)->Void,
		?retryAction:Void->Void, ?trustAction:ScmRepository->Void,
		?openFile:(ScmRepository, ScmGroup, ScmResource)->Void,
		?repositoryContextMenu:(ScmRepository, Null<ScmGroup>, UiEvent)->Void,
		?commitRepository:Void->Null<ScmRepository>, ?commitDraft:ScmRepository->String,
		?changeCommitDraft:(ScmRepository, String)->Void, ?commitAction:(ScmRepository, Bool, Bool)->Void,
		?canCommit:ScmRepository->Bool,
		?mutationAction:(ScmRepository, Null<ScmGroup>, Null<ScmResource>)->Void,
		?commitMenu:(ScmRepository, UiEvent)->Void) {
		if (source == null || theme == null || changed == null || openResource == null) throw "Invalid source-control panel";
		this.source = source;
		this.theme = theme;
		this.changed = changed;
		this.openResource = openResource;
		this.openFile = openFile;
		this.contextMenu = contextMenu;
		this.repositoryContextMenu = repositoryContextMenu;
		this.commitRepository = commitRepository;
		this.commitDraft = commitDraft;
		this.changeCommitDraft = changeCommitDraft;
		this.commitAction = commitAction;
		this.canCommit = canCommit;
		this.commitMenu = commitMenu;
		this.retryAction = retryAction == null ? function() {} : retryAction;
		this.trustAction = trustAction == null ? function(_) {} : trustAction;
		model = new ScmTreeModel(source, theme, changed, mutationAction);
	}

	public function dispose():Void {
		if (disposed) return;
		disposed = true;
		model.dispose();
	}

	public function refresh():Void model.refresh();

	public function build(context:BuildContext):RenderNode {
		var tokens = context.theme.tokens;
		var rows:Array<KeyedView> = [];
		var headerStyle = new LayoutStyle();
		headerStyle.width = LayoutAxis.grow();
		headerStyle.height = LayoutAxis.fixed(40.0);
		headerStyle.padding = new Insets(4.0, 10.0, 4.0, 10.0);
		headerStyle.childAlignY = LayoutAlignmentY.Center;
		headerStyle.childGap = 8.0;
		var title = new Text("Source Control", null, tokens.textPrimary, TextStyleOverride.text(15.0));
		var refresh = new Button("Refresh", null, function() { model.refresh(); }, "scm-refresh");
		refresh.variant = ButtonVariant.Secondary;
		rows.push(new KeyedView("header", new Row("scm-header", [
			new KeyedView("title", title), new KeyedView("spacer", new haxeon.ui.widgets.layout.Spacer("scm-header-spacer")),
			new KeyedView("refresh", refresh)
		], headerStyle)));

		if (!source.connected()) rows.push(message("connection", "Source control is disconnected", tokens.textSecondary));
		if (model.isLoading && model.repositoriesSnapshot().length == 0)
			rows.push(message("loading", "Loading repositories…", tokens.textSecondary));
		if (model.rootError != null) {
			rows.push(message("error", model.rootError, tokens.danger));
			var retry = new Button("Retry", null, function() { model.refresh(); retryAction(); }, "scm-retry");
			retry.variant = ButtonVariant.Secondary;
			rows.push(new KeyedView("retry", retry));
		} else if (!model.isLoading && model.repositoriesSnapshot().length == 0) {
			rows.push(message("empty", "No Git repository found in this folder", tokens.textSecondary));
		}

		for (repository in model.repositoriesSnapshot()) {
			var failure = model.error(repository.id);
			if (failure != null) {
				rows.push(message("error:" + repository.id, failure.message, tokens.danger));
				var repoId = repository.id;
				var retryRepository = new Button("Retry", null, function() source.refreshNow(repoId), "scm-retry:" + repoId);
				retryRepository.variant = ButtonVariant.Secondary;
				rows.push(new KeyedView("retry:" + repository.id, retryRepository));
			}
			if (!repository.trusted) {
				var messageText = source.isRemote() ? "Trust this repository on the machine that runs Git" :
					"This repository is restricted until trusted";
				rows.push(message("trust:" + repository.id, messageText, tokens.warning));
				if (!source.isRemote()) {
					var captured = repository;
					var trust = new Button("Trust Repository", null, function() trustAction(captured), "scm-trust:" + repository.id);
					trust.variant = ButtonVariant.Secondary;
					rows.push(new KeyedView("trust-action:" + repository.id, trust));
				}
			}
			var snapshot = model.snapshot(repository.id);
			if (snapshot != null && snapshot.truncated)
				rows.push(message("truncated:" + repository.id, "Untracked file list is truncated at the configured limit", tokens.warning));
		}

		var treeStyle = new LayoutStyle();
		treeStyle.width = LayoutAxis.grow();
		treeStyle.height = LayoutAxis.grow();
		treeStyle.clipHorizontal = true;
		var scroll = context.resourceState(context.id("scm-scroll:" + source.identity()), function() return new ScrollController(), function(_) {}).value;
		var tree = new TreeView("scm-tree:" + source.identity(), model, treeStyle, scroll, 560.0);
		tree.indentWidth = 10.0;
		tree.verticalGuidesOnly = true;
		tree.guidesOnInteraction = true;
		tree.compactLeafIndent = true;
		tree.expandOnSingleClick = true;
		tree.onItemActivatedWithEvent = function(key, event) {
			var repository = model.repositoryForKey(key), group = model.groupForKey(key), resource = model.resourceForKey(key);
			if (repository == null || group == null || resource == null) return;
			if ((event.modifiers & haxeon.ui.core.UiModifier.Alt) != 0 && openFile != null)
				openFile(repository, group, resource);
			else openResource(repository, group, resource);
		};
		tree.onItemContextMenu = function(key, event) {
			var repository = model.repositoryForKey(key), group = model.groupForKey(key), resource = model.resourceForKey(key);
			if (repository == null) return;
			if (group != null && resource == null && repositoryContextMenu != null) repositoryContextMenu(repository, group, event);
			else if (group == null && resource == null && repositoryContextMenu != null) repositoryContextMenu(repository, null, event);
			else if (group != null && resource != null && contextMenu != null) contextMenu(repository, group, resource, event);
		};
		rows.push(new KeyedView("tree", tree));
		var commitRepo = commitRepository == null ? null : commitRepository();
		if (commitRepo != null && source.canWrite(commitRepo.id) && commitDraft != null && changeCommitDraft != null && commitAction != null) {
			var message = commitDraft(commitRepo), commitStyle = new LayoutStyle();
			commitStyle.width = LayoutAxis.grow();
			commitStyle.height = LayoutAxis.fixed(92.0);
			commitStyle.padding = new Insets(6.0, 8.0, 6.0, 8.0);
			var editor = new TextArea("scm-commit-message:" + commitRepo.id, message,
				function(value) changeCommitDraft(commitRepo, value), commitStyle, "Commit message");
			editor.placeholder = "Commit message";
			var subject = message.split("\n")[0];
			var subjectLabel = new Text("Subject: " + subject.length + "/72", null,
				subject.length > 72 ? tokens.warning : tokens.textSecondary, TextStyleOverride.text(11.0));
			var canSubmit = canCommit == null || canCommit(commitRepo);
			var commit = new Button("Commit Staged", null, function() commitAction(commitRepo, false, false), "scm-commit-staged");
			commit.variant = ButtonVariant.Primary;
			commit.enabled = canSubmit && StringTools.trim(message).length > 0;
			var actionViews = [new KeyedView("staged", commit)];
			if (commitMenu != null) {
				var more = new Button("More…", null, null, "scm-commit-more");
				more.onClickEvent = function(event) commitMenu(commitRepo, event);
				actionViews.push(new KeyedView("more", more));
			}
			var commitActions = new Row("scm-commit-actions", actionViews);
			var commitColumnStyle = new LayoutStyle();
			commitColumnStyle.width = LayoutAxis.grow();
			commitColumnStyle.direction = haxeon.ui.LayoutDirection.TopToBottom;
			commitColumnStyle.childGap = 5.0;
			commitColumnStyle.padding = new Insets(8.0, 8.0, 8.0, 8.0);
			rows.push(new KeyedView("commit", new Column("scm-commit", [new KeyedView("editor", editor),
				new KeyedView("subject", subjectLabel), new KeyedView("actions", commitActions)], commitColumnStyle)));
		}
		var style = new LayoutStyle();
		style.width = LayoutAxis.grow();
		style.height = LayoutAxis.grow();
		style.direction = haxeon.ui.LayoutDirection.TopToBottom;
		style.childGap = 2.0;
		return new Column("source-control-panel", rows, style).build(context);
	}

	function message(key:String, value:String, color:haxeon.ui.Color):KeyedView {
		var style = new LayoutStyle();
		style.width = LayoutAxis.grow();
		style.padding = new Insets(6.0, 10.0, 6.0, 10.0);
		return new KeyedView(key, new Text(value, style, color, new TextStyleOverride(null, 13.0, null, TextWrap.WordCharacter)));
	}
}
