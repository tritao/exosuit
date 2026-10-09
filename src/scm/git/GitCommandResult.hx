package scm.git;

import haxe.io.Bytes;

class GitCommandResult {
	public final executable:String;
	public final stdout:Bytes;
	public final stderr:String;
	public final exitCode:Int;

	public function new(executable:String, stdout:Bytes, stderr:String, exitCode:Int) {
		this.executable = executable;
		this.stdout = stdout.sub(0, stdout.length);
		this.stderr = stderr;
		this.exitCode = exitCode;
	}
}
