package app;

import editor.Document;
import editor.BufferPosition;
import editor.BufferSelection;
import editor.EditorActions;
import editor.Indentation;

class IndentationTests {
	static function require(ok:Bool, message:String):Void { if (!ok) throw message; }
	public static function run(syntaxes:syntax.SyntaxRegistry):Void {
		for (width in [2, 3, 4, 8]) {
			var prefix = Indentation.prefix(width, width, true);
			var doc = new Document("Main.hx", "class A {\n" + prefix + "var a;\n" + prefix + "var b;\n" + prefix + "function f() {\n" + prefix + prefix + "f();\n" + prefix + "}\n}", syntaxes);
			require(doc.indentation.detectedWidth == width && doc.indentation.detectedSpaces == true, "failed to detect spaces " + width);
			doc.buffer.replaceAllText("\tfoo();\n\tbar();\n\tbaz();");
			require(doc.indentation.detectedWidth == width, "typing changed detected policy");
		}
		var deepSource = "class A {\n    function f() {\n    var root;\n";
		for (_ in 0...40) deepSource += "        run();\n";
		var deep = new Document("Main.hx", deepSource, syntaxes);
		require(deep.indentation.detectedWidth == 4, "deep bodies overruled repeated evidence of a smaller indentation unit");
		var tabs = new Document("Main.hx", "class A {\n\tvar a;\n\tvar b;\n\tvar c;\n}", syntaxes);
		require(tabs.indentation.detectedSpaces == false && tabs.indentation.detectedWidth == null, "tab display width was guessed from indentation");
		var ambiguous = new Document("Main.hx", "class A {\n  var a;\n    var b;\n\tvar c;\n}", syntaxes);
		require(ambiguous.indentation.detectedWidth == null && ambiguous.indentation.detectedSpaces == null, "mixed indentation should remain ambiguous");
		var comments = new Document("Main.hx", "/*\n  pretend\n  more\n  lines\n*/\nvar x = call(\n     a,\n     b,\n     c\n);", syntaxes);
		require(comments.indentation.detectedWidth == null, "comments/alignment skewed detection");
		var cases = [
			{source: "class A {\n    function f() {\n        if (ready)", expected: 12},
			{source: "class A {\n    function f() {\n        if (\n            ready\n        )", expected: 12},
			{source: "class A {\n    function f() {\n        if (ready)\n            run();", expected: 8},
			{source: "class A {\n    function f() {\n        call(\n            first,", expected: 12},
			{source: "class A {\n    function f() {\n        var x =", expected: 12},
			{source: "class A {\n    function f() {\n        var x =\n            one +", expected: 12},
			{source: "class A {\n    function f() {\n        switch (x) {\n            case 1:", expected: 16},
			{source: "class A {\n    function f() {\n        // { [ (", expected: 8},
			{source: "class A {\n    function f() {\n        var text = \"{\";", expected: 8}
		];
		for (test in cases) {
			var doc = new Document("Main.hx", test.source, syntaxes), selection = new BufferSelection(doc.buffer.endPosition());
			EditorActions.insertNewline(doc.buffer, selection, 4, true, doc.highlighter);
			require(selection.cursor.column == test.expected, "Enter context wrong: " + test.source + " got " + selection.cursor.column);
			require(doc.buffer.undo(selection) && doc.buffer.text == test.source, "context Enter was not atomic");
		}
		var source = "class A {\nfunction f() {\nif (ready)\nrun();\nswitch (x) {\ncase 1:\ncall(\na,\nb);\ndefault:\nrun();\n}\n}\n}";
		var expected = "class A {\n    function f() {\n        if (ready)\n            run();\n        switch (x) {\n            case 1:\n                call(\n                    a,\n                    b);\n            default:\n                run();\n        }\n    }\n}";
		var doc = new Document("Main.hx", source, syntaxes), selection = new BufferSelection(new BufferPosition(3, 3));
		selection.addRange(doc.buffer, new BufferPosition(6, 2), new BufferPosition(6, 0));
		require(EditorActions.reindent(doc.buffer, selection, doc.highlighter, 4, true, 4, true) && doc.buffer.text == expected, "reindent nesting wrong: " + doc.buffer.text);
		require(selection.cursor.line == 3 && selection.cursor.column == 15 && selection.rangeCount() == 2, "reindent moved caret away from text");
		require(!EditorActions.reindent(doc.buffer, selection, doc.highlighter, 4, true, 4, true), "reindent not idempotent");
		require(doc.buffer.undo(selection) && doc.buffer.text == source && selection.cursor.column == 3, "reindent undo did not restore source and selection");
		var partial = new Document("Main.hx", "class A {\nvar a;\nvar b;\n}", syntaxes), selected = new BufferSelection(new BufferPosition(2, 0));
		selected.restore(partial.buffer, new BufferPosition(2, 0), new BufferPosition(1, 0));
		EditorActions.reindent(partial.buffer, selected, partial.highlighter, 4, false, 4, false);
		require(partial.buffer.text == "class A {\n\tvar a;\nvar b;\n}", "selected-line reindent touched excluded endpoint line");
		var separate = new Document("Main.hx", "{", syntaxes), caret = new BufferSelection(separate.buffer.endPosition());
		EditorActions.insertNewline(separate.buffer, caret, 3, false, separate.highlighter, 4);
		require(separate.buffer.text == "{\n\t ", "indent size must be independent of tab width");
		var closing = new Document("Main.hx", "class A {\n    function f() {\n        run();}", syntaxes);
		var beforeClose = new BufferSelection(new BufferPosition(2, closing.buffer.line(2).length - 1));
		EditorActions.insertNewline(closing.buffer, beforeClose, 4, true, closing.highlighter);
		require(closing.buffer.line(3) == "    }" && beforeClose.cursor.column == 4, "Enter before closer did not align its owning scope");
		var braceSource = "class A {\nfunction f() {\nif (ready)\n{\nrun();\n}\n}\n}";
		var braceDoc = new Document("Main.hx", braceSource, syntaxes), braceCaret = new BufferSelection();
		EditorActions.reindent(braceDoc.buffer, braceCaret, braceDoc.highlighter, 4, true, 4, true);
		require(braceDoc.buffer.line(3) == "        {" && braceDoc.buffer.line(4) == "            run();", "brace on its own line was indented as an unbraced body");
		// Cached and cold scans must agree after edits before and after checkpoints.
		var many = "class A {\n    function f() {\n";
		for (_ in 0...150) many += "        run();\n";
		many += "        if (ready)";
		var large = new Document("Main.hx", many, syntaxes);
		for (_ in 0...3) {
			var position = large.buffer.endPosition();
			var cold = Indentation.newline(large.buffer, position, position, 4, true, large.highlighter, 4);
			var warm = Indentation.newline(large.buffer, position, position, 4, true, large.highlighter, 4, large.indentation.cache);
			require(cold.text == warm.text && cold.caret == warm.caret, "indentation checkpoint disagreed with cold scan");
			var edit = new BufferSelection(new BufferPosition(70, 0));
			large.buffer.insert(edit, "        {\n");
		}
		var protectedSource = "class A {\n/*\n   keep comment indentation\n*/\nvar text = \"first\n  keep string indentation\nlast\";\n}";
		var protectedDoc = new Document("Main.hx", protectedSource, syntaxes), protectedCaret = new BufferSelection(protectedDoc.buffer.endPosition());
		EditorActions.reindent(protectedDoc.buffer, protectedCaret, protectedDoc.highlighter, 4, true, 4, true);
		require(protectedDoc.buffer.line(2) == "   keep comment indentation" && protectedDoc.buffer.line(5) == "  keep string indentation" && protectedDoc.buffer.line(6) == "last\";", "reindent changed multiline literal/comment content");
		trace("PASS: indentation detection, Haxe contexts, reindent selection/document, caret mapping and undo");
	}
}
