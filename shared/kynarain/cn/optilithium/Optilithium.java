/*
 * New in the 1.20.6 port of OptiLithium (which is MPL-2.0, see LICENSE.txt). This file has no upstream
 * counterpart: upstream's preLaunch entrypoint (OptilithiumLoadGuard) is an empty class whose only job is to be the
 * first class loaded, while this one runs the setup.
 */
package kynarain.cn.optilithium;

import kynarain.cn.optilithium.mod.OptilithiumRuntime;

import net.fabricmc.loader.api.entrypoint.PreLaunchEntrypoint;

/**
 * OptiLithium preLaunch entrypoint.
 *
 * <p>All of the real work is done by {@link OptilithiumRuntime#ensureSetup()}: find the OptiFine jar, patch and
 * remap it, put it on the game classpath and hand the patched Minecraft classes to Fabric Loader. It is idempotent,
 * and this entrypoint is its only caller.
 *
 * <p>Failures are deliberately non-fatal: if OptiFine is missing or cannot be prepared, Fabric keeps
 * starting and the problem is reported through {@code OptilithiumError} (and therefore on the title
 * screen) plus the log.
 */
public class Optilithium implements PreLaunchEntrypoint {
	@Override
	public void onPreLaunch() {
		OptilithiumRuntime.ensureSetup();
	}
}
