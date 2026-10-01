// The Haxeon guest owns the editor loop: the page calls its exported main and
// frame functions. This executable only supplies the browser runtime and the
// NativeKit, UIKit and SceneKit C ABIs that the guest imports.
int main() {
    return 0;
}
