import java.io.DataInputStream;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.zip.GZIPInputStream;

/**
 * Dumps one class out of an OptiLithium/OptiFabric ClassCache (`.optifine/Optifine.classes.gz`).
 *
 * These bytes are the OptiFine-patched class as it comes out of the pipeline *before* the fixers run, which
 * is exactly what is needed to see what OptiFine's own patcher did to a class - for example what became of
 * BlockEntity's constructor that Lithium's @Inject(ctor = true) looks for.
 *
 * The container format is ClassCache.save()'s: char 'E', long CRC32, int+bytes mod hash, then for each class
 * an int+bytes UTF-8 name and an int+bytes class file. Java's DataInputStream writes char/int/long in
 * big-endian, so this reads them directly; no project dependency is needed.
 *
 * Usage: java DumpCacheClass <cache.gz> <class name / path> <output file>
 */
public final class DumpCacheClass {
	public static void main(String[] args) throws IOException {
		String cache = args[0];
		String wanted = args[1].replace('.', '/');
		String output = args[2];

		try (DataInputStream in = new DataInputStream(new GZIPInputStream(new FileInputStream(cache)))) {
			char revision = in.readChar();
			if (revision != 'E') {
				System.err.println("Unexpected format revision: " + (int) revision);
				System.exit(2);
			}

			in.readLong(); //expected CRC, only meaningful to the mod

			byte[] hash = new byte[in.readInt()];
			in.readFully(hash);

			int count = in.readInt();
			System.out.println("cache holds " + count + " classes");

			for (int i = 0; i < count; i++) {
				byte[] nameBytes = new byte[in.readInt()];
				in.readFully(nameBytes);
				String name = new String(nameBytes, StandardCharsets.UTF_8);

				byte[] bytes = new byte[in.readInt()];
				in.readFully(bytes);

				if (name.equals(wanted)) {
					try (FileOutputStream out = new FileOutputStream(output)) {
						out.write(bytes);
					}
					System.out.println("wrote " + name + " (" + bytes.length + " bytes) -> " + output);
					return;
				}
			}

			System.err.println("class " + wanted + " is not in the cache");
			System.exit(1);
		}
	}
}
