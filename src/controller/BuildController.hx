package controller;

import build.BuildDiagnostic;
import build.BuildOutput;
import build.BuildTask;
import build.BuildTaskCodec;
import command.CommandContext;
import command.CommandRegistry;
import commandview.CommandViewEntry;
import commandview.CommandViewProvider;
import process.OwnedProcess;
import process.ProcessManager;
import sys.FileSystem;
import sys.io.File;
import view.BuildOutputView;
import view.RootView;
import view.View;
import workspace.Project;
import workspace.Workspace;

class BuildController {
	static inline final PROBLEM_OWNER = "build";
	public final output:BuildOutput = new BuildOutput();
	public var active(default, null):Null<OwnedProcess>;

	final workspace:Workspace;
	final root:RootView;
	final context:CommandContext;
	final processes:ProcessManager;
	final openDocument:String->View;
	final reportError:(String, String)->Void;
	var emptyDrains:Int = 0;

	public function new(workspace:Workspace, root:RootView, context:CommandContext, commands:CommandRegistry, processes:ProcessManager,
			openDocument:String->View, reportError:(String, String)->Void) {
		this.workspace = workspace;
		this.root = root;
		this.context = context;
		this.processes = processes;
		this.openDocument = openDocument;
		this.reportError = reportError;
		commands.add("build:run-task", context -> openTaskPicker(), context -> workspace.activeProject != null);
		commands.add("build:cancel-task", context -> cancel(), context -> active != null);
	}

	/** Reads project-defined tasks only after this deliberate user command. */
	public function openTaskPicker():Bool {
		var project = workspace.activeProject;
		if (project == null) return false;
		var tasks = loadTasks(project);
		if (tasks.length == 0) return false;
		var entries = [for (index in 0...tasks.length) new CommandViewEntry(tasks[index].name, tasks[index].executable, Std.string(index))];
		root.commandView.open(new CommandViewProvider("Run Task: ", entries, function(query) {}, function(entry, query, backwards) {
			root.commandView.close();
			if (entry == null) return;
			var index = Std.parseInt(entry.value);
			if (index >= 0 && index < tasks.length) run(project, tasks[index]);
		}));
		return true;
	}

	public function run(project:Project, task:BuildTask):Bool {
		var previous = active;
		if (previous != null) {
			previous.cancel();
			processes.release(previous);
			active = null;
		}
		var cwd = task.cwd.length == 0 ? project.root : StringTools.startsWith(task.cwd, "/") ? task.cwd : project.root + "/" + task.cwd;
		try {
			cwd = workspace.fileSystem.normalize(cwd);
			output.reset(cwd);
			root.problems.removeOwner(PROBLEM_OWNER);
			output.append('Running ${task.name}: ${task.executable}\n');
			active = processes.start(task.executable, task.arguments, cwd, task.environment);
		} catch (error:Dynamic) {
			output.reset(project.root);
			output.append('Could not start task: ${Std.string(error)}\n');
			reportError("build", Std.string(error));
			return false;
		}
		emptyDrains = 0;
		var view = new BuildOutputView(output, root.renderer, root.theme, root.activeLeaf.width, root.activeLeaf.height, activateDiagnostic);
		view.setTitle("Build: " + task.name);
		root.openAuxiliary(view);
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
		root.problems.removeOwner(PROBLEM_OWNER);
		for (index in 0...output.lines.length) {
			var line = output.lines[index], diagnostic = line.diagnostic;
			if (diagnostic != null) root.problems.add(new feedback.Problem(PROBLEM_OWNER, Std.string(index), diagnostic.path,
				diagnostic.line, diagnostic.column, diagnostic.column + 1, line.text, 1));
		}
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
