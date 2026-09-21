/*
 * Ported from OptiLithium (https://github.com/Chocohead/OptiLithium), MPL-2.0.
 * Adapted for Minecraft 1.20.6 and 1.21.11 / Fabric Loader 0.19.x.
 */
package kynarain.cn.optilithium.mod;

import java.io.PrintWriter;
import java.io.StringWriter;

public class OptilithiumError {
	private static String error;
	private static String stack;

	public static boolean hasError() {
		return error != null;
	}

	public static String getError() {
		return error;
	}

	public static void setError(String error) {
		OptilithiumError.error = error;
	}

	public static void setError(Throwable t, String error) {
		OptilithiumError.error = error;
		logError(t);
	}

	public static void setError(String error, Object... args) {
		OptilithiumError.error = String.format(error, args);
	}

	public static void logError(Throwable t) {
		StringWriter error = new StringWriter();
		t.printStackTrace(new PrintWriter(error));
		stack = error.toString();
	}

	public static String getErrorLog() {
		return stack;
	}
}
