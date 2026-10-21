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
		return project;
	}

	public function removeProject(project:Project):Bool {
		if (!projects.remove(project)) return false;
		project.cancelIndex();
		if (activeProject == project) activeProject = projects.length == 0 ? null : projects[projects.length - 1];
		return true;
	}

	/** `immediate` (the default) rescans right away; the periodic poll passes false to let rescans be paced. */
	public function refreshProjects(directoryBudget:Int = 32, immediate:Bool = true):Bool {
		jobs.update(directoryBudget);
		var changed = false;
		for (project in projects) if (project.pollChanges(directoryBudget, immediate)) changed = true;
		return changed;
	}
}
