package syntax;

import haxe.Json;

class BuiltinSyntax {
	public static function install(registry:SyntaxRegistry):Void {
		installGrammar(registry, "Haxe", [".hx"], [], haxeGrammar());
		installGrammar(registry, "HXI", [".hxi"], [], hxiGrammar());
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
		installGrammar(registry, "JSON", [".json"], [], jsonGrammar());
		registry.add(new SyntaxDefinition("Markdown", [".md", ".markdown"], true, [], [], "", "<!--", "-->", "```", "```"));
		registry.add(new SyntaxDefinition("Lua", [".lua"], true, symbols(
			["and", "break", "do", "else", "elseif", "end", "for", "function", "goto", "if", "in", "local", "not", "or", "repeat", "return",
				"then", "until", "while"], [], ["false", "nil", "true"]), ["#!/usr/bin/env lua", "#!/usr/bin/lua"], "--", "--[[", "]]", "[[", "]]"));
		installGrammar(registry, "JavaScript", [".js", ".jsx", ".mjs", ".cjs"], [], javascriptGrammar());
		installGrammar(registry, "TypeScript", [".ts", ".tsx", ".mts", ".cts"], [], typescriptGrammar());
		installGrammar(registry, "Python", [".py", ".pyw"], ["#!/usr/bin/env python", "#!/usr/bin/env python3"], pythonGrammar());
		installGrammar(registry, "Shell", [".sh", ".bash", ".zsh"], ["#!/bin/sh", "#!/bin/bash", "#!/usr/bin/env sh", "#!/usr/bin/env bash"], shellGrammar());
	}

	static function haxeGrammar():Dynamic {
		return {
			scopeName: "source.haxe",
			name: "Haxe",
			fileTypes: ["hx"],
			patterns: [
				includeRule("#comments"),
				includeRule("#strings"),
				matchRule("\\b(?:abstract|break|case|catch|class|continue|default|do|dynamic|else|enum|extends|extern|final|for|function|if|implements|import|in|inline|interface|macro|new|override|package|private|public|return|static|switch|throw|try|typedef|untyped|using|var|while)\\b", "keyword.control.haxe"),
				matchRule("\\b(?:false|null|this|true)\\b", "constant.language.haxe"),
				matchRule("\\b(?:0[xX][0-9A-Fa-f_]+|[0-9][0-9_]*(?:\\.[0-9_]+)?(?:[eE][+-]?[0-9_]+)?)\\b", "constant.numeric.haxe"),
				matchRule("\\b[A-Z][A-Za-z0-9_]*\\b", "entity.name.type.haxe"),
				matchRule("[=+*/!<>%-]+", "keyword.operator.haxe")
			],
			repository: {
				comments: {patterns: [
					matchRule("//.*$", "comment.line.double-slash.haxe"),
					{begin: "/\\*", end: "\\*/", name: "comment.block.haxe", contentName: "comment.block.haxe"}
				]},
				strings: {patterns: [
					{begin: '"', end: '"', name: "string.quoted.double.haxe", contentName: "string.quoted.double.haxe", patterns: [
						matchRule("\\\\.", "constant.character.escape.haxe")
					]},
					{begin: "\\x27", end: "\\x27", name: "string.quoted.single.haxe", contentName: "string.quoted.single.haxe", patterns: [
						matchRule("\\\\.", "constant.character.escape.haxe")
					]}
				]}
			}
		};
	}

	static function jsonGrammar():Dynamic {
		return {
			scopeName: "source.json",
			name: "JSON",
			fileTypes: ["json"],
			patterns: [
				matchRule('"(?:\\\\.|[^"\\\\])*"(?=\\s*:)', "support.type.property-name.json"),
				includeRule("#strings"),
				matchRule("\\b(?:false|null|true)\\b", "constant.language.json"),
				matchRule("-?(?:0|[1-9][0-9]*)(?:\\.[0-9]+)?(?:[eE][+-]?[0-9]+)?", "constant.numeric.json"),
				matchRule("[{}\\[\\],:]", "punctuation.separator.json")
			],
			repository: {strings: {patterns: [
				{begin: '"', end: '"', name: "string.quoted.double.json", contentName: "string.quoted.double.json", patterns: [
					matchRule("\\\\(?:[\\\\\"/bfnrt]|u[0-9A-Fa-f]{4})", "constant.character.escape.json")
				]}
			]}}
		};
	}

	static function hxiGrammar():Dynamic {
		return {
			scopeName: "source.hxi",
			name: "HXI",
			fileTypes: ["hxi"],
			patterns: [
				includeRule("#comments"),
				includeRule("#strings"),
				captureRule("@([A-Za-z_][A-Za-z0-9_]*)", "meta.annotation.hxi", ["keyword.other.attribute.hxi"]),
				captureRule("\\b(extern\\s+fn|fn)\\s+([A-Za-z_][A-Za-z0-9_]*)\\b", "meta.function.hxi",
					["keyword.declaration.hxi", "entity.name.function.hxi"]),
				captureRule("\\b(interface|enum|flags|struct|opaque|type|handle)\\s+([A-Za-z_][A-Za-z0-9_]*)\\b",
					"meta.type.declaration.hxi", ["keyword.declaration.hxi", "entity.name.type.hxi"]),
				captureRule("\\b(const)\\s+([A-Za-z_][A-Za-z0-9_]*)\\b", "meta.constant.declaration.hxi",
					["keyword.declaration.hxi", "constant.other.hxi"]),
				captureRule("\\b(callback)\\s+([A-Za-z_][A-Za-z0-9_]*)\\b", "meta.callback.declaration.hxi",
					["keyword.declaration.hxi", "entity.name.type.hxi"]),
				matchRule("\\b(?:callback|const|enum|extern|flags|fn|handle|interface|opaque|struct|type)\\b", "keyword.control.hxi"),
				matchRule("\\b(?:array|bool32|c_bool|c_char|c_int|c_long|c_long_long|c_schar|c_short|c_size|c_uchar|c_uint|c_ulong|c_ulong_long|c_ushort|c_wchar|f32|f64|i8|i16|i32|i64|isize|nullable|ptr|u8|u16|u32|u64|usize|utf8|void)\\b", "storage.type.hxi"),
				matchRule("\\b[A-Z][A-Z0-9_]+\\b", "constant.other.hxi"),
				matchRule("\\b[A-Z][A-Za-z0-9_]*\\b", "entity.name.type.hxi"),
				captureRule("\\b([A-Za-z_][A-Za-z0-9_]*)(?=\\s*:)", "meta.parameter.hxi", ["variable.parameter.hxi"]),
				matchRule("\\b(?:0[xX][0-9A-Fa-f]+|[0-9]+)\\b", "constant.numeric.hxi"),
				matchRule("->|<<|>>|[=|]", "keyword.operator.hxi"),
				matchRule("[{}(),:;<>]", "punctuation.separator.hxi")
			],
			repository: {
				comments: {patterns: [
					matchRule("//.*$", "comment.line.double-slash.hxi"),
					{begin: "/\\*\\*", end: "\\*/", name: "comment.block.documentation.hxi", contentName: "comment.block.documentation.hxi"},
					{begin: "/\\*", end: "\\*/", name: "comment.block.hxi", contentName: "comment.block.hxi"}
				]},
				strings: {patterns: [
					{begin: '"', end: '"', name: "string.quoted.double.hxi", contentName: "string.quoted.double.hxi", patterns: [
						matchRule("\\\\.", "constant.character.escape.hxi")
					]}
				]}
			}
		};
	}

	static function javascriptGrammar():Dynamic {
		return {
			scopeName: "source.js",
			name: "JavaScript",
			fileTypes: ["js", "jsx", "mjs", "cjs"],
			patterns: [
				includeRule("#comments"),
				includeRule("#strings"),
				matchRule("\\b(?:as|async|await|break|case|catch|class|const|continue|debugger|default|delete|do|else|export|extends|finally|for|from|function|if|import|in|instanceof|let|new|of|return|static|super|switch|this|throw|try|typeof|var|void|while|with|yield)\\b", "keyword.control.js"),
				matchRule("\\b(?:false|null|true|undefined|NaN|Infinity)\\b", "constant.language.js"),
				matchRule("\\b(?:0[xX][0-9A-Fa-f]+|0[bB][01]+|0[oO][0-7]+|[0-9]+(?:\\.[0-9]*)?(?:[eE][+-]?[0-9]+)?)n?\\b", "constant.numeric.js"),
				matchRule("\\b[A-Z][A-Za-z0-9_]*\\b", "entity.name.type.js"),
				matchRule("[=+*/!<>%&|^~-]+", "keyword.operator.js")
			],
			repository: {
				comments: {patterns: [
					matchRule("//.*$", "comment.line.double-slash.js"),
					{begin: "/\\*", end: "\\*/", name: "comment.block.js", contentName: "comment.block.js"}
				]},
				strings: {patterns: [
					{begin: '"', end: '"', name: "string.quoted.double.js", contentName: "string.quoted.double.js", patterns: [
						matchRule("\\\\.", "constant.character.escape.js")
					]},
					{begin: "'", end: "'", name: "string.quoted.single.js", contentName: "string.quoted.single.js", patterns: [
						matchRule("\\\\.", "constant.character.escape.js")
					]},
					{begin: "`", end: "`", name: "string.template.js", contentName: "string.template.js", patterns: [
						matchRule("\\\\.", "constant.character.escape.js"),
						{begin: "\\$\\{", end: "\\}", name: "meta.interpolation.js", contentName: "source.js.embedded.expression", patterns: [
							includeRule("$base")
						]}
					]}
				]}
			}
		};
	}

	static function typescriptGrammar():Dynamic {
		return {
			scopeName: "source.ts",
			name: "TypeScript",
			fileTypes: ["ts", "tsx", "mts", "cts"],
			patterns: [
				matchRule("\\b(?:any|bigint|boolean|enum|implements|interface|keyof|namespace|never|number|private|protected|public|readonly|string|type|unknown)\\b", "storage.type.ts"),
				includeRule("source.js")
			]
		};
	}

	static function pythonGrammar():Dynamic {
		return {
			scopeName: "source.python",
			name: "Python",
			fileTypes: ["py", "pyw"],
			patterns: [
				matchRule("#.*$", "comment.line.number-sign.python"),
				includeRule("#strings"),
				matchRule("\\b(?:and|as|assert|async|await|break|class|continue|def|del|elif|else|except|finally|for|from|global|if|import|in|is|lambda|nonlocal|not|or|pass|raise|return|try|while|with|yield)\\b", "keyword.control.python"),
				matchRule("\\b(?:False|None|True|Ellipsis|NotImplemented)\\b", "constant.language.python"),
				matchRule("\\b(?:0[xX][0-9A-Fa-f_]+|0[bB][01_]+|0[oO][0-7_]+|[0-9][0-9_]*(?:\\.[0-9_]*)?(?:[eE][+-]?[0-9_]+)?j?)\\b", "constant.numeric.python"),
				matchRule("\\b[A-Z][A-Za-z0-9_]*\\b", "entity.name.type.python"),
				matchRule("[=+*/!<>%&|^~-]+", "keyword.operator.python")
			],
			repository: {strings: {patterns: [
				{begin: '"""', end: '"""', name: "string.quoted.triple.double.python", contentName: "string.quoted.triple.double.python", patterns: [
					matchRule("\\\\.", "constant.character.escape.python")
				]},
				{begin: "'''", end: "'''", name: "string.quoted.triple.single.python", contentName: "string.quoted.triple.single.python", patterns: [
					matchRule("\\\\.", "constant.character.escape.python")
				]},
				{begin: '"', end: '"', name: "string.quoted.double.python", contentName: "string.quoted.double.python", patterns: [
					matchRule("\\\\.", "constant.character.escape.python")
				]},
				{begin: "'", end: "'", name: "string.quoted.single.python", contentName: "string.quoted.single.python", patterns: [
					matchRule("\\\\.", "constant.character.escape.python")
				]}
			]}}
		};
	}

	static function shellGrammar():Dynamic {
		return {
			scopeName: "source.shell",
			name: "Shell Script",
			fileTypes: ["sh", "bash", "zsh"],
			patterns: [
				matchRule("#.*$", "comment.line.number-sign.shell"),
				includeRule("#strings"),
				matchRule("\\$\\{?[A-Za-z_][A-Za-z0-9_]*\\}?", "variable.other.shell"),
				matchRule("\\b(?:case|do|done|elif|else|esac|fi|for|function|if|in|select|then|time|until|while)\\b", "keyword.control.shell"),
				matchRule("\\b(?:false|true)\\b", "constant.language.shell"),
				matchRule("[=+*/!<>%&|^~-]+", "keyword.operator.shell")
			],
			repository: {strings: {patterns: [
				{begin: '"', end: '"', name: "string.quoted.double.shell", contentName: "string.quoted.double.shell", patterns: [
					matchRule("\\\\.", "constant.character.escape.shell"),
					matchRule("\\$\\{?[A-Za-z_][A-Za-z0-9_]*\\}?", "variable.other.shell")
				]},
				{begin: "'", end: "'", name: "string.quoted.single.shell", contentName: "string.quoted.single.shell", patterns: []}
			]}}
		};
	}

	static function installGrammar(registry:SyntaxRegistry, name:String, extensions:Array<String>, headers:Array<String>, source:Dynamic):Void {
		var grammar = registry.addGrammar(Json.stringify(source));
		var lineComment = "//", blockCommentStart = "/*", blockCommentEnd = "*/", stringsContinueAcrossLines = false;
		switch name {
			case "Haxe": stringsContinueAcrossLines = true;
			case "JSON": lineComment = blockCommentStart = blockCommentEnd = "";
			case "Python", "Shell": lineComment = "#"; blockCommentStart = blockCommentEnd = "";
			default:
		}
		registry.add(new SyntaxDefinition(name, extensions, true, symbols([], [], []), headers, lineComment, blockCommentStart,
			blockCommentEnd, "", "", stringsContinueAcrossLines, grammar));
	}

	static function matchRule(expression:String, name:String):Dynamic {
		return {name: name, match: expression};
	}

	static function captureRule(expression:String, name:String, scopes:Array<String>):Dynamic {
		var captures:Dynamic = {};
		for (index in 0...scopes.length) Reflect.setField(captures, Std.string(index + 1), {name: scopes[index]});
		return {match: expression, name: name, captures: captures};
	}

	static function includeRule(target:String):Dynamic {
		return {include: target};
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
