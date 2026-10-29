package syntax;

class SyntaxRegistry {
	final definitions:Array<SyntaxDefinition> = [];
	final owners:Map<String, Array<SyntaxDefinition>> = [];
	final grammars:Map<String, TextMateGrammar> = [];
	final grammarOwners:Map<String, Array<String>> = [];
	final fenceAliases:Map<String, SyntaxDefinition> = [];
	final fenceExtensionAliases:Map<String, String> = [];
	final fenceAliasOwners:Map<String, Array<String>> = [];
	final fenceAliasOwner:Map<String, String> = [];
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
		if (owned != null) for (alias in [for (key in fenceAliases.keys()) key])
			if (owned.indexOf(fenceAliases.get(alias)) >= 0) { fenceAliases.remove(alias); fenceAliasOwner.remove(alias); }
		if (owned != null) for (definition in owned) definitions.remove(definition);
		owners.remove(owner);
		var ownedAliases = fenceAliasOwners.get(owner);
		if (ownedAliases != null) for (alias in ownedAliases) if (fenceAliasOwner.get(alias) == owner) {
			fenceAliases.remove(alias); fenceExtensionAliases.remove(alias); fenceAliasOwner.remove(alias);
		}
		fenceAliasOwners.remove(owner);
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

	/** Register a fence alias for an existing definition; aliases follow owner removal. */
	public function addFenceAlias(alias:String, definition:SyntaxDefinition, owner:String = "core"):Void {
		var key = alias == null ? "" : alias.toLowerCase();
		if (!~/^[a-z0-9][a-z0-9_+.-]{0,63}$/.match(key) || definition == null || definitions.indexOf(definition) < 0)
			throw "Invalid syntax fence alias";
		if (fenceAliasOwner.exists(key)) throw 'syntax fence alias "${key}" is already registered';
		fenceAliases.set(key, definition);
		fenceAliasOwner.set(key, owner);
		var owned = fenceAliasOwners.get(owner);
		if (owned == null) { owned = []; fenceAliasOwners.set(owner, owned); }
		owned.push(key);
	}

	/** Resolve an alias through the latest registered extension, including plugin overrides. */
	public function addFenceExtensionAlias(alias:String, extension:String, owner:String = "core"):Void {
		var key = alias == null ? "" : alias.toLowerCase();
		var suffix = extension == null ? "" : extension.toLowerCase();
		if (!~/^[a-z0-9][a-z0-9_+.-]{0,63}$/.match(key) || !~/^[a-z0-9][a-z0-9_+-]{0,63}$/.match(suffix))
			throw "Invalid syntax fence alias";
		if (fenceAliasOwner.exists(key)) throw 'syntax fence alias "${key}" is already registered';
		fenceExtensionAliases.set(key, suffix); fenceAliasOwner.set(key, owner);
		var owned = fenceAliasOwners.get(owner);
		if (owned == null) { owned = []; fenceAliasOwners.set(owner, owned); }
		owned.push(key);
	}

	/** Resolve a language hint without treating it as a path or inspecting code content. */
	public function findFence(hint:String):SyntaxDefinition {
		var key = hint == null ? "" : StringTools.trim(hint).toLowerCase();
		if (!~/^[a-z0-9][a-z0-9_+.-]{0,63}$/.match(key)) return plainText;
		var alias = fenceAliases.get(key);
		if (alias != null) return alias;
		var suffix = fenceExtensionAliases.get(key);
		if (suffix != null) {
			var index = definitions.length;
			while (index > 0) {
				index--;
				for (extension in definitions[index].extensions)
					if (extension.toLowerCase() == "." + suffix) return definitions[index];
			}
			return plainText;
		}
		var index = definitions.length;
		while (index > 0) {
			index--;
			var definition = definitions[index];
			if (definition.name.toLowerCase() == key) return definition;
			for (extension in definition.extensions)
				if (extension.toLowerCase() == "." + key) return definition;
		}
		return plainText;
	}

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
