package plugin;

import editor.Document;

/** Shared editor markers with deterministic lookup and owner cleanup. */
class PluginGutterMarkerRegistry {
	final values:Array<PluginGutterMarker> = [];
	public var revision(default, null):Int = 0;

	public function new() {}

	public function add(owner:String, id:String, document:Document, startLine:Int, endLine:Int,
			kind:PluginGutterMarkerKind):PluginGutterMarker {
		if (owner == null || owner.length == 0 || id == null || id.length == 0 || document == null || kind == null)
			throw "Gutter markers require an owner, id, document and kind";
		if (startLine < 0 || endLine < startLine || endLine >= document.buffer.lineCount())
			throw "Gutter marker lines must be an ordered range inside the document";
		if (find(owner, id) != null) throw 'gutter marker "$owner:$id" is already registered';
		var value = new PluginGutterMarker(owner, id, document, startLine, endLine, kind);
		values.push(value);
		revision++;
		return value;
	}

	public function find(owner:String, id:String):Null<PluginGutterMarker> {
		for (value in values) if (value.owner == owner && value.id == id) return value;
		return null;
	}

	public function forDocument(document:Document):Array<PluginGutterMarker> {
		var result = [for (value in values) if (value.document == document) value];
		result.sort(function(a, b) {
			var order = a.startLine - b.startLine;
			if (order == 0) order = a.endLine - b.endLine;
			if (order == 0) order = Reflect.compare(a.owner + ":" + a.id, b.owner + ":" + b.id);
			return order;
		});
		return result;
	}

	public function remove(value:PluginGutterMarker):Bool {
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
