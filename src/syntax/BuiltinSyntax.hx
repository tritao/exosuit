package syntax;

class BuiltinSyntax {
	public static function install(registry:SyntaxRegistry):Void {
		registry.add(definition("Haxe", [".hx"],
			["abstract", "break", "case", "catch", "class", "continue", "default", "do", "dynamic", "else", "enum", "extends", "extern",
				"final", "for", "function", "if", "implements", "import", "in", "inline", "interface", "macro", "new", "override", "package",
				"private", "public", "return", "static", "switch", "throw", "try", "typedef", "untyped", "using", "var", "while"],
			["Any", "Array", "Bool", "Class", "Dynamic", "Enum", "Float", "Int", "Iterable", "Iterator", "Map", "Null", "String", "UInt", "Void"],
			["false", "null", "this", "true"], true));
		registry.add(definition("HXI", [".hxi"],
			["callback", "const", "enum", "extern", "flags", "fn", "handle", "interface", "opaque", "struct", "type",
				"borrowed", "callconv", "depends", "destroy", "in_array", "inout", "initial_capacity", "layout", "leaf", "length", "length_field",
				"library", "offset", "out", "out_array", "out_buffer", "owned", "retained", "span", "struct_size", "symbol", "target"],
			["array", "bool32", "c_bool", "c_char", "c_int", "c_long", "c_long_long", "c_schar", "c_short", "c_size", "c_uchar", "c_uint",
				"c_ulong", "c_ulong_long", "c_ushort", "c_wchar", "f32", "f64", "i8", "i16", "i32", "i64", "isize", "nullable", "ptr", "u8",
				"u16", "u32", "u64", "usize", "utf8", "void"], []));
		registry.add(definition("C", [".c", ".h"],
			["auto", "break", "case", "const", "continue", "default", "do", "else", "enum", "extern", "for", "goto", "if", "inline",
				"register", "restrict", "return", "sizeof", "static", "struct", "switch", "typedef", "union", "volatile", "while"],
			["bool", "char", "double", "float", "int", "long", "short", "signed", "unsigned", "void"], ["false", "NULL", "true"]));
		registry.add(definition("C++", [".cc", ".cpp", ".cxx", ".c++", ".hh", ".hpp", ".hxx", ".h++", ".inl", ".cu", ".ino"],
			["alignas", "alignof", "asm", "auto", "break", "case", "catch", "class", "concept", "const", "consteval", "constexpr", "constinit",
				"continue", "decltype", "default", "delete", "do", "else", "enum", "explicit", "export", "extern", "for", "friend", "goto", "if",
				"inline", "mutable", "namespace", "new", "noexcept", "operator", "override", "private", "protected", "public", "requires", "return",
				"sizeof", "static", "struct", "switch", "template", "throw", "try", "typedef", "typename", "union", "using", "virtual", "while"],
			["bool", "char", "char8_t", "char16_t", "char32_t", "double", "float", "int", "long", "short", "signed", "unsigned", "void", "wchar_t"],
			["false", "NULL", "nullptr", "this", "true"]));
		registry.add(new SyntaxDefinition("JSON", [".json"], true, symbols([], [], ["false", "null", "true"]), [], "", "", ""));
		registry.add(new SyntaxDefinition("Markdown", [".md", ".markdown"], true, [], [], "", "<!--", "-->", "```", "```"));
		registry.add(new SyntaxDefinition("Lua", [".lua"], true, symbols(
			["and", "break", "do", "else", "elseif", "end", "for", "function", "goto", "if", "in", "local", "not", "or", "repeat", "return",
				"then", "until", "while"], [], ["false", "nil", "true"]), ["#!/usr/bin/env lua", "#!/usr/bin/lua"], "--", "--[[", "]]", "[[", "]]"));
		registry.add(new SyntaxDefinition("Shell", [".sh", ".bash"], true, symbols(
			["case", "do", "done", "elif", "else", "esac", "fi", "for", "function", "if", "in", "select", "then", "time", "until", "while"],
			[], ["false", "true"]), ["#!/bin/sh", "#!/bin/bash", "#!/usr/bin/env sh", "#!/usr/bin/env bash"], "#", "", "", "", "", true));
	}

	public static function definition(name:String, extensions:Array<String>, keywords:Array<String>, types:Array<String>, literals:Array<String>,
			stringsContinueAcrossLines:Bool = false):SyntaxDefinition {
		return new SyntaxDefinition(name, extensions, true, symbols(keywords, types, literals), [], "//", "/*", "*/", "", "",
			stringsContinueAcrossLines);
	}

	static function symbols(keywords:Array<String>, types:Array<String>, literals:Array<String>):Map<String, Int> {
		var symbols:Map<String, Int> = [];
		for (word in keywords) symbols.set(word, HighlightToken.KEYWORD);
		for (word in types) symbols.set(word, HighlightToken.TYPE);
		for (word in literals) symbols.set(word, HighlightToken.LITERAL);
		return symbols;
	}
}
