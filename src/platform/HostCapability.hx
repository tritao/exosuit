package platform;

/** Services an editor host can actually provide. */
enum HostCapability {
	Clipboard;
	Filesystem;
	Processes;
	Threads;
	LocalIpc;
	Terminal;
	LanguageServices;
	Url;
	SourcePlugins;
}
