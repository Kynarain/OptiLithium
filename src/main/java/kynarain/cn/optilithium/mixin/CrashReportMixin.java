/*
 * Ported from OptiLithium (https://github.com/Chocohead/OptiLithium), MPL-2.0.
 * Adapted for Minecraft 1.20.6 and 1.21.11 / Fabric Loader 0.19.x.
 */

package kynarain.cn.optilithium.mixin;

import java.io.File;
import java.util.Optional;

import org.apache.commons.lang3.reflect.ConstructorUtils;

import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Unique;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

import net.minecraft.util.crash.CrashReport;
import net.minecraft.util.crash.CrashReportSection;

import kynarain.cn.optilithium.mod.OptilithiumError;
import kynarain.cn.optilithium.mod.OptilithiumSetup;
import kynarain.cn.optilithium.mod.OptifineVersion;

@Mixin(CrashReport.class)
abstract class CrashReportMixin {
	private static CrashReportSection makeSection(CrashReport crash, String name) {
		try {
			return ConstructorUtils.invokeExactConstructor(CrashReportSection.class, name);
		} catch (ReflectiveOperationException e) {
			return new CrashReportSection(name);
		}
	}

	@Unique
	private final CrashReportSection optifine = makeSection((CrashReport) (Object) this, "OptiLithium")
			.add("OptiFine jar designed for", OptifineVersion.minecraftVersion)
			.add("OptiFine jar version", OptifineVersion.version)
			.add("OptiFine jar status", () -> {
				if (OptifineVersion.jarType != null) {
					switch (OptifineVersion.jarType) {
					case MISSING:
						return "Not found";

					case CORRUPT_ZIP:
						return "Found corrupt jar whilst searching";

					case INCOMPATIBLE:
						return "Incompatible with the current OptiLithium";

					case INTERNAL_ERROR:
						return "Error whilst searching";

					case DUPLICATED:
						return "Multiple valid jars found";

					case OPTIFINE_INSTALLER:
						return "Valid OptiFine installer";

					case OPTIFINE_MOD:
						return "Valid OptiFine mod";

					case SOMETHING_ELSE:
					default:
						return "Unexpected state: " + OptifineVersion.jarType;
					}
				} else {
					return "Unsearched";
				}
			})
			.add("OptiFine remapped jar", Optional.ofNullable(OptilithiumSetup.optifineRuntimeJar).map(jar -> jar.toString().replace(File.separatorChar, '/')).orElse(null))
			.add("OptiLithium error", () -> {
				if (OptilithiumError.hasError()) {
					return OptilithiumError.getError();
				} else {
					return "<None>";
				}
			})
		;

	// Selected by DESCRIPTOR, with no name at all.
	//
	// The method is called addStackTrace on 1.20 (and 1.20.1 through 1.20.6) and addDetails from 1.21 on; its
	// intermediary name (method_555) and its descriptor never changed. Writing the name in the annotation
	// means writing it in the NAMED namespace, which Loom remaps through the mappings of the release being
	// built - so a mixin built for 1.21 carries "addDetails" into a 1.20 client, where no such method exists,
	// and the whole mod fails to load:
	//
	//   Mixin apply for mod optilithium failed optilithium.mixins.json:CrashReportMixin -> net.minecraft.class_128
	//   Critical injection failure: @Inject annotation on addStackTrace could not find any targets matching
	//   'addDetails' in net/minecraft/class_128. No refMap loaded.
	//
	// A descriptor selector is namespace independent, so one source builds correctly for the whole line. It is
	// safe here because (StringBuilder) is unique in CrashReport: the class's other StringBuilder method is
	// the toString-like build method, and 1.20's addStackTrace is the only (StringBuilder) overload.
	@Inject(method = "(Ljava/lang/StringBuilder;)V", at = @At("RETURN"))
	private void addStackTrace(StringBuilder builder, CallbackInfo info) {
		optifine.addStackTrace(builder.append("\n\n"));
	}
}
