package ui;

import completion.CompletionItem;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.Insets;
import haxeon.ui.TextWrap;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.View;
import haxeon.ui.core.UiEventKind;
import haxeon.ui.core.TextStyleOverride;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.layout.Column;
import haxeon.ui.widgets.layout.Row;
import haxeon.ui.widgets.scroll.ScrollView;
import haxeon.ui.widgets.scroll.ScrollAxis;
import haxeon.ui.widgets.scroll.ScrollController;
import haxeon.ui.widgets.text.Text;
import haxeon.ui.semantics.Semantics;
import haxeon.ui.semantics.AccessibilityRole;
import haxeon.ui.semantics.AccessibilityState;

/** Presentation only: filtering, ordering and insertion remain owned by completion. */
class CompletionPopupContent implements View {
	public static inline var RowHeight = 24.0;
	public static inline var RowGap = 4.0;
	public static inline var Padding = 8.0;
	public static inline var MaxListHeight = 236.0;
	final items:Array<CompletionItem>;
	final selected:Int;
	final scroll:ScrollController;
	final select:Int->Void;
	final accept:Int->Void;

	public function new(items:Array<CompletionItem>, selected:Int, scroll:ScrollController, select:Int->Void, accept:Int->Void) {
		this.items = items; this.selected = selected; this.scroll = scroll;
		this.select = select; this.accept = accept;
	}

	public function build(context:BuildContext):RenderNode {
		var tokens = context.theme.tokens;
		var width = Math.max(1.0, Math.min(440.0, context.viewportWidth - 16.0));
		var rows:Array<KeyedView> = [];
		for (index in 0...items.length) {
			var item = items[index], active = index == selected;
			var style = new LayoutStyle();
			style.width = LayoutAxis.grow(); style.height = LayoutAxis.fixed(RowHeight);
			style.padding = new Insets(6.0, 3.0, 6.0, 3.0);
			style.childGap = 8.0;
			style.clipHorizontal = true; style.clipVertical = true;
			style.background = active ? tokens.selection : tokens.surfaceRaised;
			style.radiusTopLeft = 4.0; style.radiusTopRight = 4.0;
			style.radiusBottomLeft = 4.0; style.radiusBottomRight = 4.0;
			var badge = new LayoutStyle(); badge.width = LayoutAxis.fixed(44.0);
			var label = new LayoutStyle(); label.width = LayoutAxis.grow(); label.clipHorizontal = true;
			var detail = new LayoutStyle(); detail.width = LayoutAxis.fixed(Math.min(160.0, width * 0.38)); detail.clipHorizontal = true;
			var children = [
				new KeyedView("kind", new Text(item.kindLabel(), badge, tokens.textSecondary, new TextStyleOverride(null, 11.0, null, TextWrap.None))),
				new KeyedView("label", new Text(item.label, label, tokens.textPrimary, new TextStyleOverride(null, 13.0, null, TextWrap.None)))
			];
			if (item.displayDetail().length > 0)
				children.push(new KeyedView("detail", new Text(item.displayDetail(), detail, tokens.textSecondary, new TextStyleOverride(null, 12.0, null, TextWrap.None))));
			rows.push(new KeyedView("row" + index, new CompletionRow(new Row("lang-row-" + index, children, style),
				item, index, items.length, active, select, accept)));
		}
		var listStyle = new LayoutStyle(); listStyle.width = LayoutAxis.fixed(width);
		listStyle.padding = new Insets(8.0, Padding, 8.0, Padding); listStyle.childGap = RowGap;
		listStyle.background = tokens.surfaceRaised;
		var list = new Column("lang-content", rows, listStyle);
		var selectedItem = items[selected];
		var description = selectedItem.displayDetail();
		if (selectedItem.documentation.length > 0)
			description += (description.length > 0 ? "\n" : "") + selectedItem.documentation;
		if (description.length > 4000) description = description.substring(0, 4000) + "…";
		var availableHeight = Math.max(1.0, context.viewportHeight - 16.0);
		var hintHeight = Math.min(24.0, availableHeight * 0.2);
		var detailsHeight = description.length == 0 ? 0.0 : Math.min(64.0, availableHeight * 0.25);
		var viewport = new LayoutStyle(); viewport.width = LayoutAxis.fixed(width);
		viewport.height = LayoutAxis.fit(0.0, Math.max(1.0, Math.min(MaxListHeight, availableHeight - hintHeight - detailsHeight)));
		var content:Array<KeyedView> = [new KeyedView("list", new ScrollView("language-scroll", list, viewport, ScrollAxis.Vertical, scroll))];
		if (description.length > 0) {
			var details = new LayoutStyle(); details.width = LayoutAxis.grow(); details.height = LayoutAxis.fixed(detailsHeight);
			details.padding = new Insets(12.0, 6.0, 12.0, 6.0); details.clipVertical = true; details.clipHorizontal = true;
			content.push(new KeyedView("documentation", new Text(description, details, tokens.textSecondary, new TextStyleOverride(null, 12.0, null, TextWrap.WordCharacter))));
		}
		var hint = new LayoutStyle(); hint.width = LayoutAxis.grow(); hint.height = LayoutAxis.fixed(hintHeight);
		hint.padding = new Insets(12.0, 4.0, 12.0, 4.0); hint.clipHorizontal = true;
		content.push(new KeyedView("hint", new Text("Up/Down select · Tab / Enter accept · Esc dismiss", hint, tokens.textSecondary, new TextStyleOverride(null, 11.0, null, TextWrap.None))));
		var panel = new LayoutStyle(); panel.width = LayoutAxis.fixed(width); panel.background = tokens.surfaceRaised;
		return new Column("completion-panel", content, panel).build(context);
	}
}

private class CompletionRow implements View {
	final child:View;
	final item:CompletionItem;
	final index:Int;
	final count:Int;
	final selected:Bool;
	final select:Int->Void;
	final accept:Int->Void;
	public function new(child:View, item:CompletionItem, index:Int, count:Int, selected:Bool, select:Int->Void, accept:Int->Void) {
		this.child = child; this.item = item; this.index = index; this.count = count;
		this.selected = selected; this.select = select; this.accept = accept;
	}
	public function build(context:BuildContext):RenderNode {
		var node = child.build(context);
		node.semantics = new Semantics(AccessibilityRole.ListItem, item.label + " " + item.kindLabel() + " " + item.displayDetail());
		node.semantics.positionInSet = index + 1; node.semantics.setSize = count;
		if (selected) node.semantics.states |= AccessibilityState.Selected;
		node.on(UiEventKind.HoverEnter, function(_) select(index));
		node.on(UiEventKind.Click, function(event) { accept(index); event.preventDefault(); });
		return node;
	}
}
