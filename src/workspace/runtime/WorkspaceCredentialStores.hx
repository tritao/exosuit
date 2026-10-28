package workspace.runtime;

import workspace.transport.RelayMachineEndpoint;

/**
	Where relay secrets live: the OS credential store, shared by the workspace daemon (which writes the
	machine bearer and the Noise static key) and suit (which reads the bearer to hold the machine socket).

	`EXOSUIT_RELAY_TEST_CREDENTIALS_DIR` switches both to a file store in that directory, but only together
	with `EXOSUIT_RELAY_ALLOW_LOOPBACK_HTTP=1`, the local-Worker development switch, so a test never
	touches the user's credential store and a real install never stores secrets in files.
**/
class WorkspaceCredentialStores {
	public static function relay():WorkspaceCredentialStore {
		var directory = Sys.getEnv("EXOSUIT_RELAY_TEST_CREDENTIALS_DIR");
		if (directory != null && directory.length > 0 && Sys.getEnv("EXOSUIT_RELAY_ALLOW_LOOPBACK_HTTP") == "1")
			return new FileWorkspaceCredentialStore(directory);
		return new NativeWorkspaceCredentialStore();
	}

	/** The account under which a workspace's machine bearer is stored. */
	public static function machineAccount(endpoint:RelayMachineEndpoint):String
		return "relay:" + endpoint.origin + "/machine/" + endpoint.machineId;
}
