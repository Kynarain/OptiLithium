/*
 * New in the 1.20.6 port of OptiLithium (which is MPL-2.0, see LICENSE.txt). This file has no upstream
 * counterpart.
 */
package kynarain.cn.optilithium.mod;

import java.nio.file.Path;

import kynarain.cn.optilithium.patcher.ClassCache;

/**
 * Result of preparing OptiFine: the remapped OptiFine jar (which must be added to the game classpath)
 * plus the cache of patched Minecraft classes that replace the game's own ones.
 */
public record OptifineRuntime(Path remappedJar, ClassCache classCache) {
}
