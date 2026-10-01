package plugin;

import editor.Document;

class PluginDecorationRegistry {
	final values:Array<PluginDecoration> = [];
	public var revision(default, null):Int = 0;

	public function new() {}

	public function add(owner:String, id:String, document:Document, line:Int, startColumn:Int, endColumn:Int, color:Int, kind:PluginDecorationKind = Background):PluginDecoration {
		if (id.length == 0) throw "decoration id cannot be empty";
		if (line < 0 || startColumn < 0 || endColumn < startColumn ||
			endColumn == startColumn && kind != WholeLineBackground)
			throw "decoration range must be ordered and non-negative; only whole-line backgrounds may be empty";
		if (find(owner, id) != null) throw 'decoration "$owner:$id" is already registered';
		var value = new PluginDecoration(owner, id, document, line, startColumn, endColumn, color, kind);
		values.push(value);
		revision++;
		return value;
	}

	public function find(owner:String, id:String):Null<PluginDecoration> {
		for (value in values) if (value.owner == owner && value.id == id) return value;
		return null;
	}

	public function forDocument(document:Document):Array<PluginDecoration> {
		var result = [for (value in values) if (value.document == document) value];
		result.sort(function(a, b) {
			var order = a.line - b.line;
			if (order == 0) order = a.startColumn - b.startColumn;
			if (order == 0) order = Reflect.compare(a.owner + ":" + a.id, b.owner + ":" + b.id);
			return order;
		});
		return result;
	}

	public function remove(value:PluginDecoration):Bool {
		if (!values.remove(value)) return false;
		revision++;
		return true;
	}
	public function removeOwner(owner:String):Void {
		var index = values.length;
		while (index > 0) {
			index--;
			if (values[index].owner == owner) {
				values.splice(index, 1);
				revision++;
			}
		}
	}
}
