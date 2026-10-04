package ui;

import LayoutAxis;
import LayoutStyle;
import TextLayout;
import TextWrap;
import nativekit.editorkit.TextDocument;
import nativekit.ui.core.BuildContext;
import nativekit.ui.core.Key;
import nativekit.ui.core.RenderNode;
import nativekit.ui.core.TextStyleOverride;
import nativekit.ui.core.View;
import nativekit.ui.theme.TextRole;
import nativekit.ui.widgets.controls.Tabs;
import nativekit.ui.widgets.overlays.Tooltip;
import nativekit.ui.widgets.scroll.ScrollAxis;
import nativekit.ui.widgets.scroll.ScrollController;
import nativekit.ui.widgets.scroll.ScrollView;
import nativekit.ui.widgets.text.Text;

/** Editor headers keep their natural widths inside a horizontally scrollable rail. */
class EditorTabsView implements View {
	static inline final LABEL_WIDTH = 180.0;
	final tabs:Tabs;
	final filenames:Map<String, String>;
	final dark:Bool;

	public function new(tabs:Tabs, filenames:Map<String, String>, dark:Bool) {
		this.tabs = tabs;
		this.filenames = filenames;
		this.dark = dark;
	}

	public function build(context:BuildContext):RenderNode {
		return context.withScope(new Key("editor-tab-icons"), function() {
			var atlas = context.resourceState(context.id("seti-atlas"), function() return new SetiIconAtlas(),
				function(value) value.dispose()).value;
			var memo = context.state(context.id("tab-labels"), new Map<String, String>()).value;
			var typography = context.resolveTextRole(TextRole.Button, TextStyleOverride.paragraph(TextWrap.None));
			for (index in 0...tabs.items.length) {
				var item = tabs.items[index];
				var filename = filenames.get(item.key);
				if (filename != null) item.iconView = new SetiFileIcon(atlas, filename, dark);
				var textStyle = typography.textStyle;
				var cacheKey = item.label + ":" + textStyle.font + ":" + textStyle.fontSize + ":" + textStyle.letterSpacing;
				var label = memo.get(cacheKey);
				if (label == null && context.fonts != null) {
					var layout = TextLayout.createStyled(context.fonts, item.label, 100000.0, textStyle, typography.paragraphStyle);
					label = item.label;
					if (layout.measure().width > LABEL_WIDTH) {
						var document = new TextDocument(item.label);
						var low = 0, high = document.codepointCount;
						while (low < high) {
							var count = (low + high + 1) >> 1;
							var candidate = document.sliceCodepoints(0, count) + "…";
							layout.setText(candidate);
							if (layout.measure().width <= LABEL_WIDTH) low = count; else high = count - 1;
						}
						label = document.sliceCodepoints(0, low) + "…";
					}
					layout.dispose();
					if ([for (_ in memo.keys()) 1].length > 128) memo.clear();
					memo.set(cacheKey, label);
				}
				var displayed = new nativekit.ui.widgets.controls.TabItem(item.key, item.label, item.content, item.enabled, item.icon, label);
				displayed.iconView = item.iconView;
				tabs.items[index] = displayed;
			}
			var root = tabs.build(context);
			var strip = root.children[0].detach();
			strip.layout.style.width = LayoutAxis.fit();
			var headers = strip.children.copy();
			var active:Null<RenderNode> = null;
			var tooltips:Array<RenderNode> = [];
			for (index in 0...headers.length) {
				var header = headers[index].detach();
				if (tabs.items[index].key == tabs.selectedKey) active = header;
				var textStyle = new LayoutStyle();
				textStyle.width = LayoutAxis.fixed(300);
				var tooltip = new Tooltip("tab-tooltip:" + tabs.items[index].key,
					new BuiltTabView(header), new Text(tabs.items[index].label, textStyle, null,
						TextStyleOverride.paragraph(TextWrap.WordCharacter)), 0, 40);
				var built = tooltip.build(context);
				tooltips.push(built);
				strip.add(built);
			}
			var state = context.state(context.id("tab-scroll-state"), new TabScrollState()).value;
			var style = new LayoutStyle();
			style.width = LayoutAxis.grow();
			style.height = LayoutAxis.fixed(40);
			var scroll = new ScrollView("editor-tab-scroll", new BuiltTabView(strip), style, ScrollAxis.Horizontal, state.controller);
			scroll.showScrollbar = false;
			scroll.onScroll = function(event) {
				if (event.deltaX == 0 && state.controller.scrollBy(event.deltaY, 0)) {
					event.preventDefault();
					event.stopPropagation();
				}
			};
			var viewport = scroll.build(context);
			viewport.setStyleIdentity("scroll-view", "editor-tab-scroll");
			for (tooltip in tooltips) tooltip.onResolved(function(_) {
				if (viewport.resolved == null || tooltip.resolved == null) return;
				var rail = viewport.globalBounds();
				var anchor = tooltip.globalBounds();
				var width = Math.max(1, Math.min(300, rail.width - 12));
				var x = Math.max(rail.x + 6 - anchor.x, Math.min(0, rail.x + rail.width - 6 - anchor.x - width));
				var tip = tooltip.children[1];
				var label = tip.children[0];
				if (tip.layout.style.positionX != x || label.layout.style.width.value != width) {
					tip.layout.style.positionX = x;
					label.layout.style.width = LayoutAxis.fixed(width);
					context.requestLayoutFeedback();
				}
			});
			var panels = root.children.copy();
			for (panel in panels) panel.detach();
			root.add(viewport);
			for (panel in panels) root.add(panel);
			root.onResolved(function(_) {
				if (active == null || viewport.resolved == null || active.resolved == null) return;
				var bounds = viewport.globalBounds();
				if (state.selected == tabs.selectedKey && state.width == bounds.width) return;
				state.selected = tabs.selectedKey;
				state.width = bounds.width;
				var tab = active.globalBounds();
				var next = state.controller.offsetX;
				if (tab.x < bounds.x) next += tab.x - bounds.x;
				else if (tab.x + tab.width > bounds.x + bounds.width) next += tab.x + tab.width - bounds.x - bounds.width;
				if (state.controller.jumpTo(next, 0)) context.requestLayoutFeedback();
			});
			return root;
		});
	}
}

private class BuiltTabView implements View {
	final node:RenderNode;
	public function new(node:RenderNode) this.node = node;
	public function build(context:BuildContext):RenderNode return node;
}

private class TabScrollState {
	public final controller = new ScrollController();
	public var selected:String = "";
	public var width:Float = -1;
	public function new() {}
}
