/*
 * New in OptiLithium (which is MPL-2.0, see LICENSE.txt). This file has no OptiFabric counterpart.
 *
 * Reads a class of the game that is running, by its runtime name, and remembers it.
 *
 * Two fixers need to answer "does the game provide this member?" before they take something away from a
 * patched class, and both need the same three properties:
 *
 *   - it must read BYTES and never reflect on a game class. A single Class.getMethods() while the patched
 *     classes are being prepared loads every type in those method signatures and pins the class to vanilla
 *     forever - the failure mode the pipeline's own comment warns about;
 *   - a class it cannot read must come back as null, not as an exception, because the caller's reaction to
 *     "unknown" is to be conservative, and an exception in a fixer fails the whole class;
 *   - it must cache, because a fixer asking about a supertype chain does it once per patched class.
 *
 * The name is in the runtime namespace, so it is intermediary on the obfuscated releases and official on
 * 26.1+. That is exactly what `getClassByteArray` expects.
 */
package kynarain.cn.optilithium.patcher.fixes;

import java.util.HashMap;
import java.util.Map;

import org.objectweb.asm.ClassReader;
import org.objectweb.asm.tree.ClassNode;

import net.fabricmc.loader.impl.launch.FabricLauncherBase;

final class GameClasses {
	private static final Map<String, ClassNode> CACHE = new HashMap<>();

	private GameClasses() {
	}

	/** The game's class, with code and frames skipped because only its members are of interest. Null if absent. */
	static ClassNode read(String internalName) {
		if (CACHE.containsKey(internalName)) return CACHE.get(internalName);

		ClassNode node = null;

		try {
			byte[] bytes = FabricLauncherBase.getLauncher().getClassByteArray(internalName.replace('/', '.'), false);

			if (bytes != null) {
				node = new ClassNode();
				new ClassReader(bytes).accept(node, ClassReader.SKIP_CODE | ClassReader.SKIP_DEBUG | ClassReader.SKIP_FRAMES);
			}
		} catch (Throwable t) {
			// Not fatal: the caller treats an unreadable class as "the member is not provided there".
		}

		CACHE.put(internalName, node);

		return node;
	}
}
