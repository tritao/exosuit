package terminalsession;

/** Terminal profiles with caller-managed registration lifetimes. */
class TerminalProfileRegistry {
    final registered:Array<TerminalProfileRegistration> = [];

    public function new() {}

    /** Pass a plugin context's own() hook to retire the entry on disable or unload. */
    public function add(owner:String, name:String, profile:TerminalProfile,
            own:(Void->Void)->Void):TerminalProfileRegistration {
        if (owner == null || owner.length == 0 || owner.indexOf(":") >= 0 || owner.indexOf(" ") >= 0 || own == null ||
                profile == null || name == null || name.length == 0 ||
                name.indexOf(":") >= 0 || name.indexOf(" ") >= 0)
            throw "Terminal profile needs a plugin owner, name, and profile";
        if (find(owner, name) != null)
            throw 'Terminal profile "$owner:$name" is already registered';
        var entry = new TerminalProfileRegistration(owner, name, profile.copy());
        own(function() { registered.remove(entry); });
        registered.push(entry);
        return entry;
    }

    public function find(owner:String, name:String):Null<TerminalProfileRegistration> {
        for (entry in registered)
            if (entry.owner == owner && entry.name == name) return entry;
        return null;
    }

    public function profiles():Array<TerminalProfileRegistration>
        return registered.copy();
}
