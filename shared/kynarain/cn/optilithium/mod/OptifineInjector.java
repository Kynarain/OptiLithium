/*
 * Ported from OptiLithium (https://github.com/Chocohead/OptiLithium), MPL-2.0.
 * Adapted for Minecraft 1.20.6 and 1.21.11 / Fabric Loader 0.19.x.
 *
 * Changes from upstream: upstream turned each cached OptiFine patched class into a Mixin class
 * replacer (through Fabric-ASM) that ran when the class was loaded. Here the same transformation is
 * done eagerly at preLaunch and the resulting bytes are handed to Loader's game transformer, which is
 * consulted for every class before Mixin runs. The transformation itself - the version specific fixes,
 * the frame check and the access widening - is unchanged.
 */
package kynarain.cn.optilithium.mod;

import java.lang.reflect.Modifier;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Deque;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;

import org.objectweb.asm.ClassReader;
import org.objectweb.asm.ClassWriter;
import org.objectweb.asm.tree.AbstractInsnNode;
import org.objectweb.asm.tree.ClassNode;
import org.objectweb.asm.tree.FieldNode;
import org.objectweb.asm.tree.FrameNode;
import org.objectweb.asm.tree.MethodNode;

import it.unimi.dsi.fastutil.objects.Object2IntArrayMap;
import it.unimi.dsi.fastutil.objects.Object2IntMap;

import net.fabricmc.loader.api.FabricLoader;
import net.fabricmc.loader.impl.launch.FabricLauncherBase;

import kynarain.cn.optilithium.patcher.ClassCache;
import kynarain.cn.optilithium.patcher.fixes.ClassFixer;
import kynarain.cn.optilithium.patcher.fixes.OptifineFixer;

/**
 * Applies the version specific fixes to the cached OptiFine patched classes and produces the final
 * bytecode that takes over from the game's own classes.
 */
public class OptifineInjector {
	/** Game classes read for the fixes and for frame computation, keyed by internal name (null = not present). */
	private static final Map<String, ClassNode> GAME_CLASSES = new HashMap<>();

	private final ClassCache classCache;

	public OptifineInjector(ClassCache classCache) {
		this.classCache = classCache;
	}

	/**
	 * @return the patched classes by dot separated class name, ready for {@link GameTransformerHook}
	 */
	public Map<String, byte[]> setup() {
		Map<String, ClassNode> classes = new LinkedHashMap<>();
		List<String> names = new ArrayList<>(classCache.getClasses());
		int skipped = 0;
		int failed = 0;

		for (String name : names) {
			byte[] bytes = classCache.popClass(name);
			if (bytes == null) continue;

			if (OptifineFixer.INSTANCE.shouldSkip(name)) {
				skipped++;
				continue;
			}

			try {
				classes.put(name, readClass(bytes));
			} catch (Throwable t) {
				//One bad class should not take the whole game down; report it and keep the vanilla class
				failed++;
				System.err.println("[OptiLithium] Failed to read the patched class " + name + ", it will not be replaced");
				t.printStackTrace();
			}
		}

		//classes OptiFine does not patch but that Fabric API injects into anyway: take them over ourselves, so the
		//same fixers can keep those injections from failing the class (see OptifineFixer#registerExtraClass)
		for (String extra : OptifineFixer.INSTANCE.getExtraClasses()) {
			if (classes.containsKey(extra)) continue;

			try {
				byte[] bytes = net.fabricmc.loader.impl.launch.FabricLauncherBase.getLauncher()
						.getClassByteArray(extra.replace('/', '.'), false);

				if (bytes == null) {
					System.err.println("[OptiLithium] No bytes for the extra class " + extra + ", leaving it to the game");
					continue;
				}

				classes.put(extra, readClass(bytes));
				System.out.println("[OptiLithium] Took over " + extra + " on our own (OptiFine does not patch it)");
			} catch (Throwable t) {
				System.err.println("[OptiLithium] Could not take over the extra class " + extra + ": " + t);
			}
		}
		//OptiFine's patches declare a few Minecraft fields under their obfuscated name with a descriptor that
		//differs from the mappings, so the remapper could not rename them; put the real names back first
		List<OptifineMappings.FieldRename> renames = OptifineMappings.findFieldRenames(classes);

		if (!renames.isEmpty()) {
			int applied = OptifineMappings.applyFieldRenames(classes, renames);
			System.out.println("[OptiLithium] Restored " + applied + " field name(s) OptiFine left obfuscated: "
					+ OptifineMappings.describe(renames));
		}

		// Two passes, and the split is load-bearing rather than cosmetic.
		//
		// A fixer can need two different classes in a fixed order: InitMultiTexIdFix patches the game's texture
		// class (where OptiFine's field lives) and also OptiFine's own ShadersTex (which calls the getter), and
		// the second half cannot run until the first has recorded which class owns the field. The class cache is
		// ordered by the jar it came from and the extras are appended after it, so iterating one combined map
		// would put the game class first only by luck.
		//
		// A class can be registered as an extra AND arrive in the cache - class_11681 does, because OptiFine
		// patches it on some releases and not others, and the registration covers the releases where it does
		// not. Patching such a class twice adds its fixers' methods twice and the game then refuses the class:
		//
		//   ClassFormatError: Duplicate method name "optilithium$movingBlocks" with signature "..." in class
		//   file net/minecraft/class_11681
		//
		// so an extra that the first loop already produced is skipped. Set is small; the alternative was to make
		// every such fixer idempotent, which is a property nobody can check from the fixer's own code.
		Map<String, byte[]> patched = new HashMap<>(classes.size() * 2);
		Set<String> cachePrepared = new HashSet<>();

		for (Map.Entry<String, ClassNode> entry : classes.entrySet()) {
			if (OptifineFixer.INSTANCE.hasExtraClass(entry.getKey())) cachePrepared.add(entry.getKey());

			try {
				patched.put(entry.getKey().replace('/', '.'), patch(entry.getKey(), entry.getValue()));
			} catch (Throwable t) {
				failed++;
				System.err.println("[OptiLithium] Failed to prepare the patched class " + entry.getKey() + ", it will not be replaced");
				t.printStackTrace();
			}
		}

		for (String extra : OptifineFixer.INSTANCE.getExtraClasses()) {
			ClassNode node = classes.get(extra);

			if (node == null || cachePrepared.contains(extra)) continue;

			try {
				patched.put(extra.replace('/', '.'), patch(extra, node));
			} catch (Throwable t) {
				failed++;
				System.err.println("[OptiLithium] Failed to prepare the taken-over class " + extra + ", it will not be replaced");
				t.printStackTrace();
			}
		}

		System.out.printf("[OptiLithium] Prepared %d patched classes (%d skipped, %d failed)%n", patched.size(), skipped, failed);

		return patched;
	}

	private byte[] patch(String name, ClassNode source) {
		ClassNode game = readGameClass(name);
		List<ClassFixer> fixers = OptifineFixer.INSTANCE.getFixers(name);
		byte[] beforeFixers = null;

		// Names this class was expected under, when the caller asks for it. A fixer that never fires is
		// indistinguishable in the log from one that fired and chose to do nothing, and the difference decides
		// where to look next - so the two facts (did the fixer list reach this class, did the game class
		// resolve) are printed on demand rather than inferred.
		//
		// This is what found the silent registration mismatch behind the 1.21.6 crash: the fixer for GlTexture
		// was registered under its Mojang path while the class being patched is named class_10868, so the list
		// reaching the class was empty of it and nothing anywhere said so.
		//   -Doptilithium.traceClasses=<comma-separated fragments of class names>
		String trace = System.getProperty("optilithium.traceClasses");

		if (trace != null && matchesAny(name, trace)) {
			System.out.println("[OptiLithium] patching '" + name + "': fixers=" + fixers.size()
					+ ", game class " + (game == null ? "NOT FOUND" : "found")
					+ ", super=" + (source.superName == null ? "-" : source.superName));
		}

		//Remember the access the game class had, so the patched one stays at least as accessible
		Object2IntMap<String> memberToAccess = new Object2IntArrayMap<>(source.methods.size() + source.fields.size());
		memberToAccess.defaultReturnValue(-1);

		if (game != null) {
			for (MethodNode method : game.methods) {
				memberToAccess.put(method.name + method.desc, method.access);
			}
			for (FieldNode field : game.fields) {
				memberToAccess.put(field.name + ' ' + field.desc, field.access);
			}
		}

		//Lets make every class we touch match the access it used to have
		source.access = widerAccess(game != null ? game.access : source.access, source.access);

		for (MethodNode method : source.methods) {
			int access = memberToAccess.getInt(method.name + method.desc);
			if (access != -1) method.access = widerAccess(access, method.access);
		}
		for (FieldNode field : source.fields) {
			int access = memberToAccess.getInt(field.name + ' ' + field.desc);
			if (access != -1) field.access = widerAccess(access, field.access);
		}

		if (game != null && !fixers.isEmpty()) {
			//Serialised with a plain writer, so the frames are exactly OptiFine's own: comparing this with the same
			//serialisation *after* the fixers tells whether any of them actually changed the class. It matters because
			//a global fixer (MissingOverrideFix is registered for every class) makes "fixers" non-empty everywhere,
			//and recomputing frames for classes nobody touched is not harmless: on 1.21.8 it turned a local the game
			//verifier needs to be Entity into java/lang/Object in class_983.method_62593, and the game then refused
			//the class with "VerifyError: Bad type on operand stack in putfield". OptiFine's own frames are the ones
			//its compiler produced for that body, so they are kept unless a fixer really rewrites something.
			beforeFixers = serialise(source);

			fixers.forEach(classFixer -> classFixer.fix(source, game));
		}

		//Frames are read expanded; Mixin needs usable ones and complains loudly about null locals
		for (MethodNode methodNode : source.methods) {
			for (AbstractInsnNode insnNode : methodNode.instructions.toArray()) {
				if (insnNode instanceof FrameNode && ((FrameNode) insnNode).local == null) {
					System.err.println("[OptiLithium] Frame with null locals in " + name + '#' + methodNode.name + methodNode.desc);
				}
			}
		}

		if (beforeFixers != null && Arrays.equals(beforeFixers, serialise(source))) {
			return beforeFixers; //No fixer changed it: hand OptiFine's bytes over untouched
		}

		//Frames come from OptiFine's patches and are preserved for untouched classes. The fixers rewrite
		//descriptors though (KeyboardFix turns Screen parameters into Element ones), which invalidates the
		//shipped frames - the verifier then rejects the class with "Inconsistent stackmap frames". Those few
		//classes get their frames recomputed instead.
		//
		// So honour a class's fixers when they declare that they cannot invalidate a frame - see
		// ClassFixer#keepsFrames. The global fixers are exempt from that declaration ON PURPOSE: one of them is
		// registered for every class, so including them would make the check always false and quietly put
		// everything back on the recomputing path - which is exactly what happened the first time this was
		// written, and it is why a class whose fixers only substitute an instruction still failed to be
		// prepared.
		boolean framesKept = true;

		for (ClassFixer fixer : fixers) {
			if (!OptifineFixer.INSTANCE.isGlobalFix(fixer) && !fixer.keepsFrames()) {
				framesKept = false;
				break;
			}
		}

		// The decision is VERIFIED before it is used: the frame-preserving bytes are read back, so a class that
		// would not load is not handed to Fabric Loader. A fixer that changes a descriptor while claiming to
		// keep frames is a bug, and this catches it here rather than as an "Inconsistent stackmap frames"
		// VerifyError in the middle of a world load.
		if (framesKept) {
			ClassWriter plain = new ClassWriter(ClassWriter.COMPUTE_MAXS);
			source.accept(plain);

			byte[] kept = plain.toByteArray();

			dump(name, kept);

			try {
				// CheckClassAdapter, not a bare read: a plain ClassNode.accept accepts bytecode the verifier
				// will reject, so it cannot answer "is this form loadable" - which is the whole question here.
				org.objectweb.asm.util.CheckClassAdapter.verify(new ClassReader(kept), false, new java.io.PrintWriter(System.err));

				return kept;
			} catch (Throwable t) {
				System.err.println("[OptiLithium] " + name + ": the frames-preserved form of this class cannot be read ("
						+ t + "), so its frames are recomputed instead");
			}
		}

		ClassWriter writer = beforeFixers == null ? new ClassWriter(0) : new FrameComputingWriter();
		source.accept(writer);

		byte[] out = writer.toByteArray();

		dump(name, out);

		return out;
	}

	/**
	 * Writes the FINAL bytecode of a class a fixer changed when -Doptilithium.dumpFixed=&lt;dir&gt; is set.
	 *
	 * <p>The class cache in .optilithium/ holds the state BEFORE the fixers, so without this there is no way to
	 * see what a fixer actually produced - which is what a VerifyError has to be diagnosed against.</p>
	 */
	private static void dump(String name, byte[] bytes) {
		String dumpDir = System.getProperty("optilithium.dumpFixed");

		if (dumpDir == null) return;

		try {
			java.io.File target = new java.io.File(dumpDir, name + ".class");
			target.getParentFile().mkdirs();
			java.nio.file.Files.write(target.toPath(), bytes);
		} catch (Throwable t) {
			System.err.println("[OptiLithium] Could not dump the fixed " + name + ": " + t);
		}
	}

	/** The class as it currently stands, with its frames left exactly as they were read. */
	private static byte[] serialise(ClassNode source) {
		ClassWriter writer = new ClassWriter(0);
		source.accept(writer);

		return writer.toByteArray();
	}

	/** True when {@code name} contains any of the comma-separated fragments in {@code fragments}. */
	private static boolean matchesAny(String name, String fragments) {
		for (String fragment : fragments.split(",")) {
			String trimmed = fragment.trim();

			if (!trimmed.isEmpty() && name.contains(trimmed)) return true;
		}

		return false;
	}

	/** Recomputes stack map frames, resolving the game's class hierarchy whenever it can. */
	private final class FrameComputingWriter extends ClassWriter {
		FrameComputingWriter() {
			super(ClassWriter.COMPUTE_FRAMES | ClassWriter.COMPUTE_MAXS);
		}

		@Override
		protected String getCommonSuperClass(String type1, String type2) {
			// -Doptilithium.traceFrames=true prints every hierarchy question this writer answers. It is the only
			// way to tell a recomputed frame apart from a shipped one: the answer shows up in the class's
			// StackMapTable as java/lang/Object, and a wrong answer there is a fatal VerifyError whose message
			// names the method but never the pair that produced it.
			boolean trace = Boolean.getBoolean("optilithium.traceFrames");

			try {
				Set<String> supertypes = allSupertypes(type1);

				if (supertypes != null) {
					// The most specific common supertype, and the order of the three tests is the whole
					// correctness argument. Two other orders were tried in game, and BOTH produce
					// java/lang/Object for a pair of plain classes, which is a frame the verifier rejects:
					//
					//   class_278 + class_284 -> java/lang/Object   although class_284 extends class_278
					//   VerifyError: Bad return type ... Type 'java/lang/Object' is not assignable to
					//   'net/minecraft/class_278'   [1.21.1, class_5944.method_35785]
					//
					//   - walking type2 up and returning the first member of supertypes(type1): every
					//     supertype set contains java/lang/Object, so the walk matches as soon as it reaches
					//     Object - immediately, for any two classes.
					//   - walking type2 up but testing membership before equality: type2's own supertypes are
					//     what is in the set, so the walk returns type2's PARENT rather than type2 itself
					//     whenever type2 is the subtype.
					//
					// Testing the subtype case explicitly, against sets that include each type itself, and
					// only then walking type2 upward, gives class_278 for that pair.
					// Reproduce offline with tools/FrameResolveTest.java.
					Set<String> other = allSupertypes(type2);

					if (other != null && other.contains(type1)) {
						if (trace) System.err.println("[OptiLithium/frames] " + type1 + " + " + type2 + " -> " + type1);
						return type1;
					}

					if (supertypes.contains(type2)) {
						if (trace) System.err.println("[OptiLithium/frames] " + type1 + " + " + type2 + " -> " + type2);
						return type2;
					}

					String up = walk(supertypes, type2);

					if (up != null) {
						if (trace) System.err.println("[OptiLithium/frames] " + type1 + " + " + type2 + " -> " + up);
						return up;
					}

					//Two interface types have no common class, and Object is what the verifier accepts for them. For two
					//classes Object is almost always wrong, and a wrong frame is fatal at runtime ("VerifyError: Bad
					//type on operand stack"), so name the pair instead of degrading quietly - this is how class_983 on
					//1.21.8 and class_898 on 1.21.3 lost the type of a local the game needed.
					System.err.println("[OptiLithium] No common supertype for " + type1 + " and " + type2
							+ " in the class hierarchy we can see, the recomputed frame will say java/lang/Object");

					return "java/lang/Object";
				}

				if (trace) System.err.println("[OptiLithium/frames] " + type1 + " + " + type2 + " -> hierarchy unknown, falling back");
			} catch (Throwable t) {
				System.err.println("[OptiLithium] Could not compare " + type1 + " with " + type2 + ": " + t);
				//fall through to the standard implementation
			}

			try {
				String answer = super.getCommonSuperClass(type1, type2); //JDK and library classes

				if (trace) System.err.println("[OptiLithium/frames] " + type1 + " + " + type2 + " -> " + answer + " (from the class loader)");

				return answer;
			} catch (Throwable t) {
				System.err.println("[OptiLithium] No common supertype for " + type1 + " and " + type2 + ": " + t
						+ ", the recomputed frame will say java/lang/Object");

				return "java/lang/Object";
			}
		}
	}

	/**
	 * Walks {@code from} and its superclasses until one of them is in {@code candidates}, or null when the
	 * chain runs out. The game's own hierarchy is preferred over the class loader's: a class that the patched
	 * set replaces must not be resolved through the loader, or the two hierarchies disagree.
	 */
	private static String walk(Set<String> candidates, String from) {
		String type = from;

		while (type != null) {
			if (candidates.contains(type)) return type;

			ClassNode node = gameClass(type);
			type = node != null ? node.superName : null;
		}

		return null;
	}

	/** Every class and interface {@code internalName} extends or implements, or null when it is unknown. */
	private static Set<String> allSupertypes(String internalName) {
		ClassNode start = gameClass(internalName);
		if (start == null) return null;

		Set<String> supertypes = new HashSet<>();
		Deque<String> queue = new ArrayDeque<>();
		queue.add(internalName);

		while (!queue.isEmpty()) {
			String name = queue.poll();
			ClassNode node = gameClass(name);

			if (node == null) continue; //Unknown type, the caller falls back to something conservative

			if (node.superName != null && supertypes.add(node.superName)) {
				queue.add(node.superName);
			}

			for (String iface : node.interfaces) {
				if (supertypes.add(iface)) queue.add(iface);
			}
		}

		return supertypes;
	}

	private static ClassNode readClass(byte[] bytes) {
		ClassNode node = new ClassNode();
		new ClassReader(bytes).accept(node, ClassReader.EXPAND_FRAMES);

		return node;
	}

	/** The game's own version of a patched class (intermediary in production), used for the fixes and the access levels. */
	private static ClassNode readGameClass(String internalName) {
		ClassNode node = gameClass(internalName);

		if (node == null) {
			System.err.println("[OptiLithium] The game has no class " + internalName + ", the patcher fixes are skipped for it");
		}

		return node;
	}

	/** Reads a class of the running game (cached); null when it is not available. */
	private static ClassNode gameClass(String internalName) {
		if (GAME_CLASSES.containsKey(internalName)) return GAME_CLASSES.get(internalName);

		ClassNode node = null;

		try {
			byte[] bytes = FabricLauncherBase.getLauncher().getClassByteArray(internalName.replace('/', '.'), false);
			if (bytes != null) node = readClass(bytes);
		} catch (Throwable t) {
			//Not fatal, callers fall back to something conservative
		}

		GAME_CLASSES.put(internalName, node);

		return node;
	}

	private static int widerAccess(int origin, int target) {
		if (!Modifier.isFinal(origin)) target &= ~Modifier.FINAL;

		switch (target & 0x7) {
		case Modifier.PUBLIC:
			return target;

		case Modifier.PROTECTED:
			return Modifier.isPublic(origin) ? (target & (~0x7)) | Modifier.PUBLIC : target;

		case 0:
			return Modifier.isPrivate(origin) ? target : (target & (~0x7)) | (origin & 0x7);

		case Modifier.PRIVATE:
			return (target & (~0x7)) | (origin & 0x7);

		default:
			if (FabricLoader.getInstance().isDevelopmentEnvironment()) {
				throw new AssertionError("Unexpected access: " + target + " (transformed from " + origin + ')');
			}

			return target;
		}
	}
}
