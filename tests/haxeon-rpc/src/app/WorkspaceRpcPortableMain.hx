package app;

class WorkspaceRpcPortableMain {
	public static function main():Int {
		RpcCompatibilityTests.run();
		WorkspaceRpcTests.run();
		return 42;
	}
}
