package ui;

import FontCollection;
import TextLayout;
import TextStyle;
import ParagraphStyle;
import TextWrap;

/** One isolated font collection per mounted icon group, with shared retained glyph layouts. */
class SetiIconAtlas {
	final fonts:FontCollection;
	final layouts:Map<String, TextLayout> = new Map();

	public function new() {
		fonts = FontCollection.create();
		try fonts.addData("seti.ttf", SetiIconData.fontData()) catch (error:Dynamic) {
			fonts.dispose();
			throw error;
		}
	}

	public function layout(id:String, dark:Bool):TextLayout {
		var key = id + (dark ? ":dark" : ":light");
		var cached = layouts.get(key);
		if (cached != null) return cached;
		var definition = SetiIconData.definition(id, dark);
		var glyph = TextLayout.create(fonts, definition.glyph, 32.0,
			new TextStyle(21.0), new ParagraphStyle(TextWrap.None));
		glyph.setColor(definition.color);
		layouts.set(key, glyph);
		return glyph;
	}

	public function dispose():Void {
		for (layout in layouts) layout.dispose();
		layouts.clear();
		fonts.dispose();
	}
}
