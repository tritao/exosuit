/** Entry of the Android host module. The Activity drives it through UiBridge, not through main. */
class Main {
	public static function main():Int {
		UiBridge.init();
		return 0;
	}
}
