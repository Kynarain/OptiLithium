import java.io.FileReader;
import java.util.Properties;

/**
 * Reads an OptiFine optionsshaders.txt the way OptiFine does, and prints what came out.
 *
 * Written while 1.21.9 would not load a shader pack. That failure splits into two very different questions that
 * look identical in the game log - does the config file yield the pack name at all, or does OptiFine find the
 * name and then reject the pack? The log prints "[Shaders] No shaderpack loaded." either way, and the answer
 * here was "the name is read correctly", which is what moved the search into OptiFine's own bytecode and found
 * the dead store that ClearShaderPackLoadedFix removes.
 *
 * Usage: java ShaderConfigProbe <optionsshaders.txt> [propertyName]
 */
public final class ShaderConfigProbe {
	public static void main(String[] args) throws Exception {
		if (args.length < 1) {
			System.err.println("usage: ShaderConfigProbe <optionsshaders.txt> [propertyName]");
			System.exit(1);
		}
		String property = args.length > 1 ? args[1] : "shaderPack";

		Properties config = new Properties();

		// Exactly OptiFine's sequence for the pack name: seed the default, load the file over it, read back.
		config.setProperty(property, "");
		try (FileReader reader = new FileReader(args[0])) {
			config.load(reader);
		}

		Object raw = config.getProperty(property, "");
		System.out.println("file        : " + args[0]);
		System.out.println(property + " = [" + raw + "]  (length " + String.valueOf(raw).length() + ")");

		if (String.valueOf(raw).isEmpty()) {
			System.out.println("=> OptiFine would treat this as no shaderpack selected, so the problem is the FILE");
		} else {
			System.out.println("=> the name is read correctly, so the problem is downstream of the config");
		}

		for (String key : config.stringPropertyNames()) {
			System.out.println("  key: [" + key + "]");
		}
	}
}