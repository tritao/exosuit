package controller;

import build.BuildDiagnostic;
import build.BuildOutput;
import build.BuildTask;
import build.BuildTaskCodec;
import command.CommandContext;
import command.CommandRegistry;
import commandview.CommandViewEntry;
import commandview.CommandViewProvider;
import core.WorkbenchHost;
import process.OwnedProcess;
import process.ProcessManager;
import sys.FileSystem;
import sys.io.File;
import view.View;
import workspace.Project;
import workspace.Workspace;

class BuildController {
	static inline final PROBLEM_OWNER = "build";
	public final available:Bool;
	public final output:BuildOutput = new BuildOutput();
	public var active(default, null):Null<OwnedProcess>;

	final workspace:Workspace;
	final root:WorkbenchHost;
	final context:CommandContext;
	final processes:ProcessManager;
	final openDocument:String->View;
	final reportError:(String, String)->Void;
	var emptyDrains:Int = 0;
	var activeProjectRoot:String = "";

	public function new(workspace:Workspace, root:WorkbenchHost, context:CommandContext, commands:CommandRegistry, processes:ProcessManager,
			openDocument:String->View, reportError:(String, String)->Void, available:Bool = true) {
		this.available = available && processes.available;
		this.workspace = workspace;
		this.root = root;
		this.context = context;
		this.processes = processes;
		this.openDocument = openDocument;
		this.reportError = reportError;
		root.setBuildDiagnosticHandler(activateDiagnostic);
		if (this.available) {
			commands.add("build:show-output", context -> root.showBuildOutput("Build Output", output));
			commands.add("build:run-task", context -> openTaskPicker(), context -> workspace.activeProject != null);
			commands.add("build:cancel-task", context -> cancel(), context -> active != null);
		}
	}

	/** Reads project-defined tasks only after this deliberate user command. */
	public function openTaskPicker():Bool {
		if (!available) { reportError("build", "Build tasks are unavailable on this host"); return false; }
		var project = workspace.activeProject;
		if (project == null) return false;
		var tasks = loadTasks(project);
		if (tasks.length == 0) return false;
		var entries = [for (index in 0...tasks.length) new CommandViewEntry(tasks[index].name, tasks[index].executable, Std.string(index))];
		root.openCommandView(new CommandViewProvider("Run Task: ", entries, function(query) {}, function(entry, query, backwards) {
			root.closeCommandView();
			if (entry == null) return;
			var index = Std.parseInt(entry.value);
			if (index >= 0 && index < tasks.length) run(project, tasks[index]);
		}));
		return true;
	}

	public function run(project:Project, task:BuildTask):Bool {
		if (!available) { reportError("build", "Build tasks are unavailable on this host"); return false; }
		var previous = active;
		if (previous != null) {
			previous.cancel();
			processes.release(previous);
			active = null;
		}
		var cwd = task.cwd.length == 0 ? project.root : StringTools.startsWith(task.cwd, "/") ? task.cwd : project.root + "/" + task.cwd;
		try {
			cwd = workspace.fileSystem.normalize(cwd);
			activeProjectRoot = project.root;
			output.reset(cwd);
			root.getProblems().removeOwner(PROBLEM_OWNER);
			output.append('Running ${task.name}: ${task.executable}\n');
			active = processes.start(task.executable, task.arguments, cwd, task.environment);
		} catch (error:Dynamic) {
			output.reset(project.root);
			output.append('Could not start task: ${Std.string(error)}\n');
			root.getProblems().replaceOwner(PROBLEM_OWNER, [feedback.Problem.scoped(PROBLEM_OWNER, "start",
				feedback.ProblemScope.Project(project.root), "Could not start task: " + Std.string(error), 1, "Build")]);
			reportError("build", Std.string(error));
			return false;
		}
		emptyDrains = 0;
		root.showBuildOutput("Build: " + task.name, output);
		return true;
	}

	public function update():Void {
		var process = active;
		if (process == null) return;
		var received = false;
		for (attempt in 0...16) {
			var stdout = process.readStdout(), stderr = process.readStderr();
			if (stdout.length == 0 && stderr.length == 0) break;
			if (stdout.length > 0) output.append(stdout);
			if (stderr.length > 0) output.append(stderr);
			received = true;
		}
		syncProblems();
		if (!process.exited()) return;
		if (received) emptyDrains = 0; else emptyDrains++;
		if (emptyDrains < 2) return;
		output.finish();
		syncProblems();
		output.append('Process exited with status ${process.exitStatus()}\n');
		processes.release(process);
		active = null;
	}

	function syncProblems():Void {
		var problems = root.getProblems();
		var published:Array<feedback.Problem> = [];
		var identities:Map<String, Int> = [];
		for (index in 0...output.lines.length) {
			var line = output.lines[index], diagnostic = line.diagnostic;
			if (diagnostic != null) {
				var identity = diagnostic.path + ":" + diagnostic.line + ":" + diagnostic.column + ":" + line.text;
				var occurrence = identities.exists(identity) ? identities.get(identity) : 0;
				identities.set(identity, occurrence + 1);
				published.push(new feedback.Problem(PROBLEM_OWNER, identity + ":" + occurrence, diagnostic.path,
					diagnostic.line, diagnostic.column, diagnostic.column + 1, line.text, 1, null, "Build"));
			}
		}
		var process = active;
		if (published.length == 0 && process != null && process.exited() && process.exitStatus() != 0)
			published.push(feedback.Problem.scoped(PROBLEM_OWNER, "exit", feedback.ProblemScope.Project(activeProjectRoot),
				"Build failed with status " + process.exitStatus(), 1, "Build", [new feedback.ProblemAction("Show build output", "build:show-output")]));
		problems.replaceOwner(PROBLEM_OWNER, published);
	}

	public function cancel():Bool {
		var process = active;
		if (process == null) return false;
		var result = process.cancel();
		if (result) output.append("Cancellation requested\n");
		return result;
	}

	public function shutdown():Void {
		var process = active;
		if (process != null) processes.release(process);
		active = null;
	}

	function loadTasks(project:Project):Array<BuildTask> {
		var path = project.root + "/.pragtical/tasks.conf";
		if (!FileSystem.exists(path)) {
			reportError("build", 'No task file at "$path"');
			return [];
		}
		try {
			return BuildTaskCodec.parse(File.getContent(path));
		} catch (error:Dynamic) {
			root.getProblems().replaceOwner(PROBLEM_OWNER, [feedback.Problem.scoped(PROBLEM_OWNER, "start",
				feedback.ProblemScope.Project(project.root), "Could not start task: " + Std.string(error), 1, "Build")]);
			reportError("build", Std.string(error));
			return [];
		}
	}

	function activateDiagnostic(diagnostic:BuildDiagnostic):Void {
		try {
			var view = openDocument(diagnostic.path);
			view.restoreCursor(diagnostic.line, diagnostic.column);
			view.cursorChanged();
		} catch (error:Dynamic) {
			reportError("build", 'Could not open "${diagnostic.path}": ${Std.string(error)}');
		}
	}
}
