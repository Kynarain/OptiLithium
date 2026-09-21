/*
 * Ported from OptiLithium (https://github.com/Chocohead/OptiLithium), MPL-2.0.
 * Adapted for Minecraft 1.20.6 and 1.21.11 / Fabric Loader 0.19.x.
 *
 * Upstream this class was also the entry point that wired up all the per-mod compatibility mixin
 * configs through Fabric-ASM early risers. That machinery is gone: loading OptiFine now lives in
 * OptilithiumRuntime, and the only state the rest of the mod needs from here is where the patched
 * OptiFine jar ended up (used by the crash report mixin).
 */
package kynarain.cn.optilithium.mod;

import java.io.File;

public final class OptilithiumSetup {
	/** The remapped OptiFine jar that was put on the game classpath, or null when OptiFine is not loaded. */
	public static File optifineRuntimeJar;

	private OptilithiumSetup() {
	}
}
