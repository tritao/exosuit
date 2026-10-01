package core;

/**
 * One-time callbacks a `WorkbenchHost` needs from `controller.FileController`
 * so its own UI (a sidebar context menu, a tab's close control, and so on)
 * can trigger file/tab operations without holding a `FileController`
 * reference itself. Wired once by `core.Application` after `FileController`
 * is constructed.
 */
typedef FileActions = {
	createFile:Void->Void,
	createFolder:Void->Void,
	renameFile:Void->Void,
	deleteFile:Void->Void,
	closeTab:Void->Void
}
