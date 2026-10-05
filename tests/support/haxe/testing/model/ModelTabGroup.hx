package testing.model;

import view.View;
import view.LayoutKind;

import core.FocusManager;

class ModelTabGroup {
	public final views:Array<View> = [];
	public var activeView(default, null):Null<View>;
	final focus:FocusManager;

	public function new(focus:FocusManager) {
		this.focus = focus;
	}

	public function add(view:View):View {
		views.remove(view);
		views.push(view);
		setActive(view);
		return view;
	}

	public function insert(view:View, index:Int):View {
		views.remove(view);
		if (index < 0) index = 0;
		if (index > views.length) index = views.length;
		views.insert(index, view);
		setActive(view);
		return view;
	}

	public function setActive(view:View):Bool {
		if (indexOf(view) < 0)
			return false;
		activeView = view;
		focus.activate(view);
		return true;
	}

	public function switchBy(delta:Int):Bool {
		if (views.length < 2 || activeView == null)
			return false;
		var index = indexOf(activeView), next = (index + delta) % views.length;
		if (next < 0)
			next += views.length;
		return setActive(views[next]);
	}

	public function close(view:View, force:Bool = false):Bool {
		var index = indexOf(view);
		if (index < 0 || view.isDirty() && !force)
			return false;
		views.remove(view);
		if (activeView == view) {
			if (views.length == 0) {
				activeView = null;
				focus.activate(null);
			} else {
				if (index >= views.length)
					index = views.length - 1;
				setActive(views[index]);
			}
		}
		view.dispose();
		return true;
	}

	public function closeActive(force:Bool = false):Bool
		return activeView != null && close(activeView, force);

	public function detach(view:View):Bool {
		var index = indexOf(view);
		if (index < 0) return false;
		views.remove(view);
		if (activeView == view) {
			activeView = views.length == 0 ? null : views[index >= views.length ? views.length - 1 : index];
			focus.activate(activeView);
		}
		return true;
	}

	public function reorderActive(delta:Int):Bool {
		if (activeView == null || views.length < 2) return false;
		var from = indexOf(activeView), to = from + delta;
		if (to < 0 || to >= views.length) return false;
		views.splice(from, 1);
		views.insert(to, activeView);
		return true;
	}

	public function indexOf(view:View):Int {
		for (index in 0...views.length)
			if (views[index] == view)
				return index;
		return -1;
	}
}
