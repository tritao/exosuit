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
	final tooltipDelay:Float;

	public function new(tabs:Tabs, filenames:Map<String, String>, dark:Bool, tooltipDelay:Float = 0.8) {
		this.tabs = tabs;
		this.filenames = filenames;
		this.dark = dark;
		this.tooltipDelay = tooltipDelay;
	}

	public function build(context:BuildContext):RenderNode {
		return context.withScope(new Key("editor-tab-icons"), function() {
			var atlas = context.resourceState(context.id("seti-atlas"), function() return new SetiIconAtlas(),
				function(value) value.dispose()).value;
			var state = context.state(context.id("tab-scroll-state"), new TabScrollState()).value;
			tabs.headerRevision = function() {
				var revision = dark + ":" + tooltipDelay + ":" + context.animations.revision + ":" +
					state.controller.offsetX + ":" + state.controller.viewportWidth;
				for (item in tabs.items) {
					var filename = filenames.get(item.key);
					revision += ":" + item.key.length + ":" + item.key + ":" + item.label.length + ":" + item.label +
						":" + item.enabled + ":" + item.icon + ":" + filename;
				}
				return revision;
			};
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
			displayed.badgeCount = item.badgeCount;
				tabs.items[index] = displayed;
			}
			tabs.transformHeaderStrip = function(strip, buildContext) return buildRail(strip, buildContext, state);
			return tabs.build(context);
		});
	}
	function buildRail(strip:RenderNode, context:BuildContext, state:TabScrollState):RenderNode {
		strip.layout.style.width = LayoutAxis.fit();
		var headers = strip.children.copy();
		var active:Null<RenderNode> = null;
		var viewport:Null<RenderNode> = null;
		for (index in 0...headers.length) {
			var header = headers[index].detach();
			if (tabs.items[index].key == tabs.selectedKey) active = header;
			var textStyle = new LayoutStyle();
			var tooltip = new TabTooltip("tab-tooltip:" + tabs.items[index].key,
				new BuiltTabView(header), new Text(tabs.items[index].label, textStyle, context.theme.tokens.textPrimary,
					new TextStyleOverride(null, 13, null, TextWrap.WordCharacter)),
				function() return viewport == null ? new Rect(0, 0, context.viewportWidth, context.viewportHeight) : viewport.globalBounds(), tooltipDelay);
			var built = tooltip.build(context);
			strip.add(built);
		}
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
		viewport = scroll.build(context);
		viewport.setStyleIdentity("scroll-view", "editor-tab-scroll");
		viewport.onResolved(function(_) {
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
		return viewport;
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
