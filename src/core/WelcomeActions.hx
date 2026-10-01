package core;

/**
 * One-time callbacks a `WorkbenchHost` needs to present an empty-workspace
 * landing state (recent projects, "new file", "open file", and so on)
 * without holding `core.Application` or its controllers directly. Wired once
 * by `core.Application` at construction.
 */
typedef WelcomeActions = {
	recentProjects:Array<String>,
	newFile:Void->Void,
	openFile:Void->Void,
	openProject:Void->Void,
	findFile:Void->Void,
	runCommand:Void->Void,
	openSettings:Void->Void,
	openPlugins:Void->Void,
	openRecent:String->Void
}
