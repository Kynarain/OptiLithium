/*
 * Ported from OptiLithium (https://github.com/Chocohead/OptiLithium), MPL-2.0.
 * Adapted for Minecraft 1.20.6 and 1.21.11 / Fabric Loader 0.19.x.
 */

package kynarain.cn.optilithium.patcher.fixes;


import org.objectweb.asm.tree.ClassNode;

public interface ClassFixer {
	void fix(ClassNode optifine, ClassNode minecraft);

	/**
	 * Whether this fixer leaves every stack map frame in the class valid, so the frames do not have to be
	 * recomputed after it runs.
	 *
	 * <p>Recomputing frames is the default and stays the default, because it is what makes a fixer that adds
	 * methods, changes descriptors or rewrites branches produce a loadable class. It is also all-or-nothing per
	 * class: ASM analyses every method, and one it cannot follow throws</p>
	 *
	 * <pre>
	 * java.lang.NegativeArraySizeException: -1
	 *   at org.objectweb.asm.Frame.merge(Frame.java:1234)
	 * </pre>
	 *
	 * <p>- which fails the whole patched class, so a one-instruction change can cost an entire class that was
	 * otherwise fine. OptiFine's {@code Shaders} is exactly that case on 1.21.9: a fixer there substitutes one
	 * instruction for another of the same size and the same stack effect, which cannot invalidate a frame, and
	 * recomputing them anyway failed the class.</p>
	 *
	 * <p>So a fixer that only makes same-size, stack-neutral substitutions overrides this to return true. It is
	 * a claim about the fixer's own edits, and the only safe way to make it is to leave the instruction list's
	 * shape, offsets and stack effects untouched.</p>
	 *
	 * @return true when every frame in a class this fixer has run on is still correct
	 */
	default boolean keepsFrames() {
		return false;
	}
}
