package feedback;

enum ProblemScope {
	File(path:String);
	Project(root:String);
	Workspace;
}
