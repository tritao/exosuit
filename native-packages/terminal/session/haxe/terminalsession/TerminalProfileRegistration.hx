package terminalsession;

/** A profile contributed by one active plugin. */
class TerminalProfileRegistration {
    public final owner:String;
    public final name:String;
    public final profile:TerminalProfile;

    public function new(owner:String, name:String, profile:TerminalProfile) {
        this.owner = owner;
        this.name = name;
        this.profile = profile;
    }

    public function id():String return owner + ":" + name;
}
