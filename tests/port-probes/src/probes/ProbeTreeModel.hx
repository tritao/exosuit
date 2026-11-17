package probes;

import haxeon.reactive.Signal;
import haxeon.ui.core.View;
import haxeon.ui.widgets.collections.TreeRootMetadata;
import haxeon.ui.widgets.collections.TreeViewModel;
import haxeon.ui.widgets.text.Text;

/**
	root
	  group
	    a
	    b
	  other
	`changes` is the D3 signal; every model method reads it, so a bump re-flattens the tree.
**/
class ProbeTreeModel implements TreeViewModel {
	public final changes = new Signal<Int>(0);

	public function new() {}

	public function rootCount():Int {
		changes.value;
		return 1;
	}

	public function rootRange(start:Int, count:Int):Array<TreeRootMetadata> {
		changes.value;
		return [new TreeRootMetadata("root", true)];
	}

	public function childCount(key:String):Int {
		changes.value;
		return key == "root" || key == "group" ? 2 : 0;
	}

	public function childKeyAt(key:String, index:Int):String {
		changes.value;
		return key == "root" ? ["group", "other"][index] : ["a", "b"][index];
	}

	public function initiallyExpanded(key:String):Bool {
		changes.value;
		return key == "root";
	}

	public function estimatedExtent():Float return 24;

	public function extentIsUniform():Bool return true;

	public function extentAt(key:String):Float return 24;

	public function buildItem(key:String):View return new Text(key);
}
