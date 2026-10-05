package core;

import view.View;

class FocusManager {
	public var activeView(default, null):Null<View>;

	public function new() {}

	public function activate(view:Null<View>):Void {
		if (activeView == view)
			return;
		if (activeView != null) activeView.deactivate();
		activeView = view;
		if (view != null) view.activate();
	}
}
