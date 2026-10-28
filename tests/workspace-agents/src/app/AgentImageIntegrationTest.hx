package app;

/** Native, provider-independent regression suite for attachment authorization and projection. */
@:access(app.AgentProviderTestMain)
class AgentImageIntegrationTest {
 static function main():Void {
  AgentImageStagingTest.run();
  AgentServiceTest.run();
  AgentSnapshotTest.run();
  AgentContentStorageTest.run();
  AgentResponseArchiveTest.run();
  AgentProviderTestMain.conversationTests();
 }
}
