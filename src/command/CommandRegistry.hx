package command;

class CommandRegistry {
	final commands:Array<Command> = [];

	public function new() {}

	public function add(name:String, perform:CommandContext->Void, ?predicate:CommandContext->Bool, ?description:String):Void {
		if (name.indexOf(":") <= 0 || name.indexOf(" ") >= 0)
			throw "invalid command name: " + name;
		for (index in 0...commands.length) {
			if (commands[index].name == name) {
				commands[index] = new Command(name, perform, predicate, description);
				return;
			}
		}
		commands.push(new Command(name, perform, predicate, description));
	}

	public function contains(name:String):Bool
		return find(name) != null;

	/** Every registered command regardless of its current predicate, for hosts that build their own command surfaces (e.g. a palette bridge) and want live enabled/disabled state rather than a filtered snapshot. */
	public function all():Array<Command>
		return commands.copy();

	public function remove(name:String):Bool {
		var command = find(name);
		return command != null && commands.remove(command);
	}

	public function isValid(name:String, context:CommandContext):Bool {
		var command = find(name);
		if (command == null)
			return false;
		var predicate = command.predicate;
		return predicate(context);
	}

	public function perform(name:String, context:CommandContext):Bool {
		var command = find(name);
		if (command == null)
			return false;
		var predicate = command.predicate;
		if (!predicate(context))
			return false;
		var action = command.perform;
		action(context);
		return true;
	}

	public function available(context:CommandContext):Array<String> {
		var result:Array<String> = [];
		for (command in commands) {
			var predicate = command.predicate;
			if (predicate(context)) result.push(command.name);
		}
		result.sort(Reflect.compare);
		return result;
	}

	public function availableCommands(context:CommandContext):Array<Command> {
		var result:Array<Command> = [];
		for (command in commands)
			if (command.predicate(context)) result.push(command);
		result.sort((left, right) -> Reflect.compare(left.name, right.name));
		return result;
	}

	function find(name:String):Null<Command> {
		for (command in commands)
			if (command.name == name)
				return command;
		return null;
	}
}
