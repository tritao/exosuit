package syntax;

class SyntaxRegistry {
	final definitions:Array<SyntaxDefinition> = [];
	final owners:Map<String, Array<SyntaxDefinition>> = [];
	final grammars:Map<String, TextMateGrammar> = [];
	final grammarOwners:Map<String, Array<String>> = [];
	public final plainText = new SyntaxDefinition("Plain Text", [], false);

	public function new() {}

	public function add(definition:SyntaxDefinition, owner:String = "core"):Void {
		for (existing in definitions)
			if (existing.name == definition.name) throw 'syntax "${definition.name}" is already registered';
		definitions.push(definition);
		var owned = owners.get(owner);
		if (owned == null) {
			owned = [];
			owners.set(owner, owned);
		}
		owned.push(definition);
	}

	public function removeOwner(owner:String):Void {
		var owned = owners.get(owner);
		if (owned != null) for (definition in owned) definitions.remove(definition);
		owners.remove(owner);
		var ownedGrammars = grammarOwners.get(owner);
		if (ownedGrammars != null) {
			for (scope in ownedGrammars) grammars.remove(scope);
			grammarOwners.remove(owner);
		}
	}

	/** Loads and registers a JSON TextMate grammar under its scope name. */
	public function addGrammar(source:String, owner:String = "core"):TextMateGrammar {
		var grammar = new TextMateGrammar(source);
		if (grammars.exists(grammar.scopeName)) throw 'TextMate scope "${grammar.scopeName}" is already registered';
		grammars.set(grammar.scopeName, grammar);
		var owned = grammarOwners.get(owner);
		if (owned == null) {
			owned = [];
			grammarOwners.set(owner, owned);
		}
		owned.push(grammar.scopeName);
		return grammar;
	}

	public function grammar(scopeName:String):Null<TextMateGrammar>
		return grammars.get(scopeName);

	public function find(path:String, header:String = ""):SyntaxDefinition {
		var lower = path.toLowerCase(), index = definitions.length;
		while (index > 0) {
			index--;
			for (extension in definitions[index].extensions)
				if (StringTools.endsWith(lower, extension.toLowerCase())) return definitions[index];
		}
		index = definitions.length;
		while (index > 0) {
			index--;
			for (prefix in definitions[index].headers)
				if (StringTools.startsWith(header, prefix)) return definitions[index];
		}
		return plainText;
	}
}
