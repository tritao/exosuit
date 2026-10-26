package workspace;

import core.DocumentManager;
import syntax.SyntaxRegistry;
import jobs.JobScheduler;

class Workspace {
	public final projects:Array<Project> = [];
	public final documents:DocumentManager;
	public final syntaxes:SyntaxRegistry;
	public final fileSystem:FileSystemService;
	public final jobs:JobScheduler;
	public var activeProject(default, null):Null<Project>;
	public var activeContext:Null<ActiveContext>;
	final listeners:Array<Void->Void> = [];
	public function subscribe(listener:Void->Void):Void->Void {
		listeners.push(listener);
		return function() { listeners.remove(listener); };
	}
	function changed():Void { for (listener in listeners.copy()) listener(); }
	public function scopedProjects():Array<Project> return activeContext == null ? projects.copy() : activeContext.projects();
	public function buildProject():Null<Project> return activeContext == null ? activeProject : activeContext.buildProject();

	public function new(syntaxes:SyntaxRegistry, ?fileSystem:FileSystemService) {
		this.syntaxes = syntaxes;
		this.fileSystem = fileSystem == null ? new FileSystemService() : fileSystem;
		documents = new DocumentManager(syntaxes, this.fileSystem);
		jobs = new JobScheduler();
	}

	public function addProject(path:String, ?ignoredNames:Array<String>):Project {
		var normalized = fileSystem.normalize(path);
		for (project in projects)
			if (project.root == normalized) {
				activeProject = project;
				return project;
			}
		var project = new Project(normalized, fileSystem, jobs, ignoredNames);
		projects.push(project);
		activeProject = project;
		changed();
		return project;
	}

	public function removeProject(project:Project):Bool {
		if (!projects.remove(project)) return false;
		project.cancelIndex();
		if (activeProject == project) activeProject = projects.length == 0 ? null : projects[projects.length - 1];
		changed();
		return true;
	}

	/** `immediate` (the default) rescans right away; the periodic poll passes false to let rescans be paced. */
	public function refreshProjects(directoryBudget:Int = 32, immediate:Bool = true):Bool {
		jobs.update(directoryBudget);
		var changed = false;
		for (project in projects) if (project.pollChanges(directoryBudget, immediate)) changed = true;
		if (activeContext != null) for (project in activeContext.projects())
			if (projects.indexOf(project) < 0 && project.pollChanges(directoryBudget, immediate)) changed = true;
		return changed;
	}
}
