import java.io.DataInputStream;
import java.io.FileInputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.zip.GZIPInputStream;

/**
 * Finds which classes in an OptiLithium ClassCache contain a given string.
 *
 * tools/DumpCacheClass.java answers "what does THIS class look like"; when the question is instead "who declares
 * or calls this method", the class name is exactly what is not known, and grepping the shipped OptiFine jar does
 * not help: OptiFine's patcher runs at runtime, so the classes it produces only ever exist inside this cache.
 * That was the wall hit while diagnosing the 1.21.6 crash in ShadersTex.initDynamicTextureNS - getMultiTexID is
 * found in four OptiFine classes, but none of them declares it, so it has to be injected into the game class by
 * a patch that is only visible here.
 *
 * Usage: java FindInCache <cache.gz> <substring> [more substrings...]
 */
public final class FindInCache {
	public static void main(String[] args) throws IOException {
		if (args.length < 2) {
			System.err.println("usage: FindInCache <cache.gz> <substring> [substring...]");
			System.exit(1);
		}
		String[] wanted = new String[args.length - 1];
		System.arraycopy(args, 1, wanted, 0, wanted.length);

		try (DataInputStream in = new DataInputStream(new GZIPInputStream(new FileInputStream(args[0])))) {
			char revision = in.readChar();
			if (revision != 'E') {
				System.err.println("Unexpected format revision: " + (int) revision);
				System.exit(2);
			}
			in.readLong();
			byte[] hash = new byte[in.readInt()];
			in.readFully(hash);
			int count = in.readInt();

			int hits = 0;
			for (int i = 0; i < count; i++) {
				byte[] nameBytes = new byte[in.readInt()];
				in.readFully(nameBytes);
				String name = new String(nameBytes, StandardCharsets.UTF_8);
				byte[] classBytes = new byte[in.readInt()];
				in.readFully(classBytes);

				String text = new String(classBytes, StandardCharsets.ISO_8859_1);
				// An empty needle lists everything. "Who references X" is not the only question worth asking of a
				// cache: "what is actually in it" decides whether a fixer's registration can ever match, and
				// answering that by guessing needles wastes a round each time.
				if (wanted.length == 1 && wanted[0].isEmpty()) {
					System.out.println(name);
					hits++;
					continue;
				}
				for (String needle : wanted) {
					if (text.contains(needle)) {
						System.out.println(name + "   <- " + needle);
						hits++;
						break;
					}
				}
			}
			System.out.println("scanned " + count + " classes, " + hits + " hit(s)");
		}
	}
}
