package ui;

import haxeon.ui.Color;
import haxeon.ui.Path;

import haxeon.ui.Insets;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.LayoutAlignmentY;
import feedback.Problem;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.TextStyleOverride;
import haxeon.ui.core.View;
import haxeon.ui.icons.IconName;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.controls.Button;
import haxeon.ui.widgets.controls.ButtonVariant;
import haxeon.ui.widgets.layout.Column;
import haxeon.ui.widgets.layout.Row;
import haxeon.ui.widgets.scroll.ScrollView;
import haxeon.ui.widgets.text.Text;
import haxeon.ui.widgets.text.MiddleEllipsisText;

/** Scope grouping is independent of the producer; state follows stable diagnostic IDs. */
class ProblemsPanel implements View {
	final host:UiWorkbenchHost;
	final roots:Array<String>;
	public function new(host:UiWorkbenchHost, ?roots:Array<String>) { this.host = host; this.roots = roots == null ? [] : roots; }

	function relative(path:String):String {
		var best = haxe.io.Path.withoutDirectory(path);
		var length = -1;
		for (root in roots) if (root.length > length && (path == root || StringTools.startsWith(path, root + "/"))) {
			length = root.length;
			best = haxe.io.Path.withoutDirectory(root) + path.substr(root.length);
		}
		return best;
	}

	public function build(context:BuildContext):RenderNode {
		var values = host.getProblems().values();
		var atlas = context.resourceState(context.id("problem-file-icons"), function() return new SetiIconAtlas(), function(value) value.dispose()).value;
		var dark = context.environment.colorScheme == haxeon.ui.style.EnvironmentColorScheme.Dark;
		var selected = context.state(context.id("problem-selection"), "");
		var collapsed = context.state(context.id("problem-groups"), new Map<String, Bool>());
		var groups:Map<String, Array<Problem>> = [];
		var keys:Array<String> = [];
		var selectedExists = false;
		for (problem in values) {
			if (problem.key() == selected.value) selectedExists = true;
			var key = problem.scopeKey();
			if (!groups.exists(key)) { groups.set(key, []); keys.push(key); }
			groups.get(key).push(problem);
		}
		if (!selectedExists && selected.value != "") selected.update("");
		keys.sort(Reflect.compare);
		var rows:Array<KeyedView> = [];
		var summaryStyle = new LayoutStyle();
		summaryStyle.padding = new Insets(12, 6, 12, 6);
		if (values.length == 0) rows.push(new KeyedView("empty", new Text("No problems reported.",
			summaryStyle, context.theme.tokens.textSecondary, TextStyleOverride.text(13))));
		for (key in keys) {
			var problems:Array<Problem> = groups.get(key);
			problems.sort(function(a, b) return a.severity != b.severity ? a.severity - b.severity : Reflect.compare(a.key(), b.key()));
			var hidden = collapsed.value.get(key) == true;
			var headerStyle = new LayoutStyle();
			headerStyle.width = LayoutAxis.grow();
			headerStyle.height = LayoutAxis.fixed(28);
			headerStyle.clipHorizontal = true;
			headerStyle.clipVertical = true;
			headerStyle.padding = new Insets(12, 0, 12, 0);
			var label = switch problems[0].scope {
				case feedback.ProblemScope.File(path): haxe.io.Path.withoutDirectory(path);
				case feedback.ProblemScope.Project(root): "Project: " + haxe.io.Path.withoutDirectory(root);
				case feedback.ProblemScope.Workspace: "Workspace";
			};
			var folder = switch problems[0].scope {
				case feedback.ProblemScope.File(path): relative(haxe.io.Path.directory(path));
				case feedback.ProblemScope.Project(root): relative(root);
				case feedback.ProblemScope.Workspace: "";
			};
			var header = new Button(label, headerStyle, function() {
				var next = collapsed.value.copy(); next.set(key, !hidden); collapsed.update(next);
			}, "problem-group:" + key);
			header.variant = ButtonVariant.Navigation;
			var icon:View = switch problems[0].scope {
				case feedback.ProblemScope.File(path): new SetiFileIcon(atlas, haxe.io.Path.withoutDirectory(path), dark);
				case feedback.ProblemScope.Project(_): new haxeon.ui.widgets.Icon("scope-icon", IconName.FolderOpen, 16, context.theme.tokens.textSecondary);
				case feedback.ProblemScope.Workspace: new haxeon.ui.widgets.Icon("scope-icon", IconName.Hierarchy, 16, context.theme.tokens.textSecondary);
			};
			var iconsStyle = new LayoutStyle(); iconsStyle.childAlignY = LayoutAlignmentY.Center; iconsStyle.childGap = 5;
			header.leadingView = new Row("group-icons", [
				new KeyedView("chevron", new haxeon.ui.widgets.Icon("chevron", hidden ? IconName.ChevronRight : IconName.ChevronDown, 14, context.theme.tokens.textSecondary)),
				new KeyedView("file", icon)
			], iconsStyle);
			header.trailingView = new Row("group-metadata", [
				new KeyedView("folder", new Text(folder, null, context.theme.tokens.textSecondary, TextStyleOverride.text(12))),
				new KeyedView("count", new haxeon.ui.widgets.controls.CountBadge(problems.length))
			], iconsStyle);
			header.accessibilityLabel = problems[0].scopeLabel() + ", " + problems.length + " problems";
			rows.push(new KeyedView("group:" + key, new FlatProblemControl(header)));
			if (hidden) continue;
			for (problem in problems) {
				var rowStyle = new LayoutStyle();
				rowStyle.width = LayoutAxis.grow();
				rowStyle.childAlignY = LayoutAlignmentY.Center;
				rowStyle.padding = new Insets(38, 0, 12, 0);
				rowStyle.childGap = 10;
				var buttonStyle = new LayoutStyle();
				buttonStyle.width = LayoutAxis.grow();
				buttonStyle.height = LayoutAxis.fixed(28);
				buttonStyle.clipHorizontal = true;
				buttonStyle.clipVertical = true;
				var button = new Button(problem.message, buttonStyle, function() {
					selected.update(problem.key()); host.activateProblem(problem);
				}, "problem:" + problem.key());
				button.variant = ButtonVariant.Navigation;
				var summary = StringTools.replace(StringTools.replace(StringTools.replace(problem.message, "\r", " "), "\n", " "), "\t", " ");
				button.labelView = new MiddleEllipsisText("message-summary", summary, false);
				button.selected = selected.value == problem.key();
				var severity = problem.severity <= 1 ? "Error" : problem.severity == 2 ? "Warning" : "Information";
				button.accessibilityLabel = severity + ": " + problem.message;
				button.leadingView = new haxeon.ui.widgets.Icon("severity", problem.severity <= 1 ? IconName.ErrorCircle : problem.severity == 2 ? IconName.AlertTriangle : IconName.InfoCircle, 16,
					problem.severity <= 1 ? context.theme.tokens.danger : problem.severity == 2 ? context.theme.tokens.warning : context.theme.tokens.info);
				var metadata = problem.source + (problem.code == "" ? "" : " (" + problem.code + ")");
				if (problem.location != null) metadata += "  [" + (problem.line + 1) + ", " + (problem.column + 1) + "]";
				rows.push(new KeyedView("row:" + problem.key(), new Row("problem-row:" + problem.key(), [
					new KeyedView("message", new FlatProblemControl(button)), new KeyedView("metadata", new Text(metadata, null, context.theme.tokens.textSecondary, TextStyleOverride.text(12)))
				], rowStyle)));
				if (selected.value == problem.key()) {
					var messageStyle = new LayoutStyle();
					messageStyle.width = LayoutAxis.grow();
					messageStyle.padding = new Insets(64, 6, 12, 6);
					rows.push(new KeyedView("message-detail:" + problem.key(), new Text(problem.message, messageStyle,
						context.theme.tokens.textPrimary, TextStyleOverride.combine(TextStyleOverride.text(12),
							TextStyleOverride.paragraph(haxeon.ui.TextWrap.WordCharacter)))));
					for (index in 0...problem.actions.length) {
						var action = problem.actions[index];
						var actionButton = new Button(action.label, null, function() host.activateProblem(problem.forAction(action)), "problem-action:" + index);
						actionButton.variant = ButtonVariant.Navigation;
						rows.push(new KeyedView("action:" + problem.key() + ":" + index, actionButton));
					}
					for (index in 0...problem.details.length) {
						var detail = problem.details[index];
						rows.push(new KeyedView("detail:" + problem.key() + ":" + index,
							new Text(detail.message, summaryStyle, context.theme.tokens.textSecondary, TextStyleOverride.text(12))));
					}
				}
			}
		}
		var style = new LayoutStyle();
		style.width = LayoutAxis.grow(); style.height = LayoutAxis.grow();
		style.background = context.theme.tokens.surfaceSunken;
		var listStyle = new LayoutStyle(); listStyle.width = LayoutAxis.grow();
		return new ScrollView("problems-scroll", new Column("problems-list", rows, listStyle), style).build(context);
	}
}

/** Diagnostic rows are flat; only hover, focus and selection receive a fill. */
private class FlatProblemControl implements View {
	final button:Button;
	public function new(button:Button) this.button = button;
	public function build(context:BuildContext):RenderNode {
		var node = button.build(context);
		var hovered = haxeon.ui.style.StyleStateUtil.contains(node.states, haxeon.ui.style.StyleState.Hovered);
		node.layout.style.background = button.selected ? context.theme.tokens.selection : hovered ? context.theme.tokens.surfaceHover : Color.rgba(0, 0, 0, 0);
		node.layout.style.radiusTopLeft = node.layout.style.radiusTopRight = node.layout.style.radiusBottomLeft = node.layout.style.radiusBottomRight = 0;
		return node;
	}
}
