package view;

import core.DocumentManager;
import core.FocusManager;
import editor.Document;

class LayoutNode {
	public static inline final DIVIDER_SIZE = 4;
	public static inline final MIN_SIZE = 120;
	public var kind(default, null):LayoutKind;
	public var tabs(default, null):TabGroup;
	public var first(default, null):Null<LayoutNode>;
	public var second(default, null):Null<LayoutNode>;
	public var divider(default, null):Int = 500;
	public var x(default, null):Int = 0;
	public var y(default, null):Int = 0;
	public var width(default, null):Int = 0;
	public var height(default, null):Int = 0;
	final focus:FocusManager;
	final documents:DocumentManager;

	public function new(focus:FocusManager, documents:DocumentManager, ?tabs:TabGroup) {
		this.focus = focus;
		this.documents = documents;
		this.tabs = tabs == null ? new TabGroup(focus) : tabs;
		kind = LayoutKind.Leaf;
	}

	public function isLeaf():Bool
		return kind == LayoutKind.Leaf;

	public function setBounds(x:Int, y:Int, width:Int, height:Int):Void {
		this.x = x;
		this.y = y;
		this.width = width;
		this.height = height;
		if (isLeaf()) {
			for (view in tabs.views)
				view.setBounds(x, y, width, height);
			return;
		}
		var available = (kind == LayoutKind.Horizontal ? width : height) - DIVIDER_SIZE;
		if (available < 0) available = 0;
		var firstSize = Std.int(available * divider / 1000), secondSize = available - firstSize,
			left = requireFirst(), right = requireSecond();
		if (available >= MIN_SIZE * 2) {
			if (firstSize < MIN_SIZE) firstSize = MIN_SIZE;
			if (firstSize > available - MIN_SIZE) firstSize = available - MIN_SIZE;
			secondSize = available - firstSize;
		} else {
			firstSize = Std.int(available / 2);
			secondSize = available - firstSize;
		}
		if (kind == LayoutKind.Horizontal) {
			left.setBounds(x, y, firstSize, height);
			right.setBounds(x + firstSize + DIVIDER_SIZE, y, secondSize, height);
		} else {
			left.setBounds(x, y, width, firstSize);
			right.setBounds(x, y + firstSize + DIVIDER_SIZE, width, secondSize);
		}
	}

	public function split(splitKind:LayoutKind, newFirst:Bool = false):LayoutNode {
		if (!isLeaf() || splitKind == LayoutKind.Leaf)
			throw "only leaf nodes can be split";
		var existing = new LayoutNode(focus, documents, tabs), created = new LayoutNode(focus, documents);
		first = newFirst ? created : existing;
		second = newFirst ? existing : created;
		tabs = new TabGroup(focus);
		kind = splitKind;
		setBounds(x, y, width, height);
		return created;
	}

	public function reset():Void {
		disposeViews();
		kind = LayoutKind.Leaf;
		tabs = new TabGroup(focus);
		first = null;
		second = null;
		divider = 500;
		setBounds(x, y, width, height);
	}

	/** Removes session branches for which no document could be restored. */
	public function pruneEmpty():Bool {
		if (isLeaf()) return tabs.views.length > 0;
		var left = requireFirst(), right = requireSecond(), leftHasViews = left.pruneEmpty(), rightHasViews = right.pruneEmpty();
		if (leftHasViews && rightHasViews) return true;
		if (leftHasViews) {
			adopt(left);
			return true;
		}
		if (rightHasViews) {
			adopt(right);
			return true;
		}
		reset();
		return false;
	}

	public function disposeViews():Void {
		if (isLeaf()) {
			for (view in tabs.views) view.dispose();
			return;
		}
		requireFirst().disposeViews();
		requireSecond().disposeViews();
	}

	public function setDivider(value:Int):Void {
		divider = value;
		if (divider < 150) divider = 150;
		if (divider > 850) divider = 850;
		setBounds(x, y, width, height);
	}

	public function leafAt(px:Int, py:Int):Null<LayoutNode> {
		if (px < x || py < y || px >= x + width || py >= y + height)
			return null;
		if (isLeaf()) return this;
		var found = requireFirst().leafAt(px, py);
		return found == null ? requireSecond().leafAt(px, py) : found;
	}

	public function dividerAt(px:Int, py:Int):Null<LayoutNode> {
		if (isLeaf()) return null;
		var left = requireFirst(), boundary = kind == LayoutKind.Horizontal ? left.x + left.width : left.y + left.height;
		if (kind == LayoutKind.Horizontal) {
			if (px >= boundary && px < boundary + DIVIDER_SIZE && py >= y && py < y + height) return this;
		} else if (py >= boundary && py < boundary + DIVIDER_SIZE && px >= x && px < x + width) return this;
		var found = left.dividerAt(px, py);
		return found == null ? requireSecond().dividerAt(px, py) : found;
	}

	public function moveDivider(px:Int, py:Int):Void {
		var total = kind == LayoutKind.Horizontal ? width - DIVIDER_SIZE : height - DIVIDER_SIZE,
			position = kind == LayoutKind.Horizontal ? px - x : py - y;
		if (total <= 0) return;
		if (total >= MIN_SIZE * 2) {
			if (position < MIN_SIZE) position = MIN_SIZE;
			if (position > total - MIN_SIZE) position = total - MIN_SIZE;
		}
		divider = Std.int(position * 1000 / total);
		if (divider < 0) divider = 0;
		if (divider > 1000) divider = 1000;
		setBounds(x, y, width, height);
	}

	public function findDocument(document:Document):Null<View> {
		if (isLeaf()) {
			for (view in tabs.views)
				if (view.getDocument() == document) return view;
			return null;
		}
		var found = requireFirst().findDocument(document);
		return found == null ? requireSecond().findDocument(document) : found;
	}

	public function containsDocument(document:Document):Bool
		return findDocument(document) != null;

	public function collapse(leaf:LayoutNode):Bool {
		if (isLeaf()) return false;
		if (first == leaf) {
			adopt(requireSecond());
			return true;
		}
		if (second == leaf) {
			adopt(requireFirst());
			return true;
		}
		return requireFirst().collapse(leaf) || requireSecond().collapse(leaf);
	}

	public function firstLeaf():LayoutNode
		return isLeaf() ? this : requireFirst().firstLeaf();

	function adopt(source:LayoutNode):Void {
		kind = source.kind;
		tabs = source.tabs;
		first = source.first;
		second = source.second;
		divider = source.divider;
		setBounds(x, y, width, height);
	}

	public function requireFirst():LayoutNode {
		if (first == null) throw "split node has no first child";
		return first;
	}

	public function requireSecond():LayoutNode {
		if (second == null) throw "split node has no second child";
		return second;
	}
}
