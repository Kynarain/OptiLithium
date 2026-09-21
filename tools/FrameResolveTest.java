import java.io.DataInputStream;
import java.io.FileInputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.HashMap;
import java.util.Map;
import java.util.zip.GZIPInputStream;

import org.objectweb.asm.ClassReader;
import org.objectweb.asm.ClassWriter;
import org.objectweb.asm.Opcodes;
import org.objectweb.asm.tree.ClassNode;
import org.objectweb.asm.tree.MethodNode;

/**
 * Answers one question about OptiLithium's frame recomputation, without launching the game: given a class
 * from an Optifine.classes.gz cache and a directory of game classes, what does the resolver say for a pair of
 * types - and what ends up in the method's StackMapTable?
 *
 * This exists because the in-game symptom is a VerifyError that names the METHOD but neither the type pair
 * nor the answer that produced it, and because every in-game round trip costs minutes. Three plausible causes
 * are separated here: (a) the first type's supertype set is computed wrong, (b) the resolver actually returns
 * the right common supertype and something else overwrites the frames, (c) the class is written by a path that
 * does not recompute frames at all.
 *
 * Usage:
 *   java FrameResolveTest <cache .gz> <class name> <game classes dir or vanilla jar> [type1] [type2]
 *
 * With no type pair it replays the frames of every method of the named class through a COMPUTE_FRAMES writer
 * and prints each hierarchy question the resolver is asked, plus the resulting StackMapTable entry count.
 */
public final class FrameResolveTest {
	private static final Map<String, ClassNode> GAME = new HashMap<>();
	private static Path gameSource;

	public static void main(String[] args) throws IOException {
		Path cache = Paths.get(args[0]);
		String wanted = args[1].replace('.', '/');
		gameSource = Paths.get(args[2]);

		byte[] bytes = readFromCache(cache, wanted);
		if (bytes == null) {
			System.err.println(wanted + " is not in " + cache);
			System.exit(1);
		}

		System.out.println("read " + wanted + " (" + bytes.length + " bytes) from the cache");

		if (args.length >= 5) {
			String t1 = args[3].replace('.', '/');
			String t2 = args[4].replace('.', '/');
			System.out.println("supertypes(" + t1 + ") = " + allSupertypes(t1));
			System.out.println("supertypes(" + t2 + ") = " + allSupertypes(t2));
			System.out.println("common supertype  = " + commonSupertype(t1, t2));
			return;
		}

		ClassNode node = new ClassNode();
		new ClassReader(bytes).accept(node, ClassReader.EXPAND_FRAMES);

		ClassWriter writer = new FrameWriter();
		try {
			node.accept(writer);
			System.out.println("recomputed the class OK (" + writer.toByteArray().length + " bytes)");
		} catch (Throwable t) {
			System.out.println("recomputation FAILED: " + t);
		}
	}

	private static final class FrameWriter extends ClassWriter {
		FrameWriter() {
			super(ClassWriter.COMPUTE_FRAMES | ClassWriter.COMPUTE_MAXS);
		}

		@Override
		protected String getCommonSuperClass(String type1, String type2) {
			System.out.println("  asked: " + type1 + " + " + type2);

			String answer = commonSupertype(type1, type2);
			System.out.println("    -> " + answer);

			return answer;
		}
	}

	/**
	 * The most specific class or interface that both types are assignable to.
	 *
	 * Two orderings were tried and are both WRONG; both are recorded here because each one produced a fatal
	 * VerifyError in game rather than a wrong-but-loadable class:
	 *
	 *   1. walk type2 up and return the first member of supertypes(type1). Every supertype set contains
	 *      java/lang/Object, so as soon as the walk reaches Object it matches - which is immediately for any
	 *      pair of plain classes. Measured: class_278 + class_284 -> java/lang/Object, although class_284
	 *      extends class_278.
	 *   2. walk type2 up and test membership first, equality second. type2's own supertype set contains
	 *      itself's supertypes only, so the sequence starts at type2's parent: class_284 -> class_278 is in
	 *      the set and is returned BEFORE the walk ever gets to type2 == type1. Same wrong answer.
	 *
	 * The working formulation is the standard one: collect ALL supertypes of one side (including the type
	 * itself), then walk the other side upward starting at the type itself and return the first hit. Starting
	 * from the type itself and walking upward is what makes it most-specific, and preferring equality first
	 * is what makes the subtype case come out right.
	 */
	private static String commonSupertype(String type1, String type2) {
		if (type1.equals(type2)) return type1;

		// The subtype case first, and each side tested against the other's supertype set - NOT with an
		// assignability predicate, whose argument order is the easiest thing in this file to get backwards.
		if (allSupertypes(type2).contains(type1)) return type1;
		if (allSupertypes(type1).contains(type2)) return type2;

		java.util.Set<String> candidates = allSupertypes(type1);

		String type = type2;

		while (type != null) {
			if (candidates.contains(type)) return type;

			ClassNode node = gameClass(type);
			type = node != null ? node.superName : null;
		}

		return "java/lang/Object";
	}

	private static java.util.Set<String> allSupertypes(String internalName) {
		java.util.Set<String> out = new java.util.LinkedHashSet<>();
		java.util.Deque<String> queue = new java.util.ArrayDeque<>();
		queue.add(internalName);

		while (!queue.isEmpty()) {
			ClassNode node = gameClass(queue.poll());
			if (node == null) continue;

			if (node.superName != null && out.add(node.superName)) queue.add(node.superName);

			for (String iface : node.interfaces) {
				if (out.add(iface)) queue.add(iface);
			}
		}

		return out;
	}

	private static ClassNode gameClass(String internalName) {
		if (GAME.containsKey(internalName)) return GAME.get(internalName);

		ClassNode node = null;

		try {
			byte[] bytes = null;
			Path entry = gameSource.resolve(internalName + ".class");

			if (Files.isRegularFile(entry)) {
				bytes = Files.readAllBytes(entry);
			} else if (Files.isRegularFile(gameSource) && gameSource.toString().endsWith(".jar")) {
				try (java.util.zip.ZipFile zip = new java.util.zip.ZipFile(gameSource.toFile())) {
					java.util.zip.ZipEntry ze = zip.getEntry(internalName + ".class");
					if (ze != null) {
						try (java.io.InputStream in = zip.getInputStream(ze)) {
							bytes = in.readAllBytes();
						}
					}
				}
			}

			if (bytes != null) {
				node = new ClassNode();
				new ClassReader(bytes).accept(node, ClassReader.SKIP_CODE | ClassReader.SKIP_DEBUG | ClassReader.SKIP_FRAMES);
			}
		} catch (Throwable t) {
			System.err.println("  (could not read " + internalName + ": " + t + ')');
		}

		GAME.put(internalName, node);

		return node;
	}

	/** ClassCache.save()'s container: char 'E', long CRC, int+bytes hash, then int+bytes name/class pairs. */
	private static byte[] readFromCache(Path cache, String wanted) throws IOException {
		try (DataInputStream in = new DataInputStream(new GZIPInputStream(new FileInputStream(cache.toFile())))) {
			if (in.readChar() != 'E') return null;

			in.readLong();

			byte[] hash = new byte[in.readInt()];
			in.readFully(hash);

			for (int i = 0, count = in.readInt(); i < count; i++) {
				byte[] nameBytes = new byte[in.readInt()];
				in.readFully(nameBytes);
				String name = new String(nameBytes, StandardCharsets.UTF_8);

				byte[] bytes = new byte[in.readInt()];
				in.readFully(bytes);

				if (name.equals(wanted)) return bytes;
			}
		}

		return null;
	}
}
