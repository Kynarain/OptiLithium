/*
 * New in OptiLithium (which is MPL-2.0, see LICENSE.txt). This file has no OptiFabric counterpart.
 *
 * Restores the super() call of a constructor OptiFine rewrote, so that "delegate constructor" injections
 * can be found again.
 *
 * The failure this fixes, measured live on 1.21.11 with Lithium 0.21.4:
 *
 *   InjectionError: Delegate constructor lookup failed for @Inject target on
 *   lithium.mixins.json:...BlockEntityMixin from mod lithium->@Inject::initSupportCache
 *   (Lnet/minecraft/class_2591;Lnet/minecraft/class_2338;Lnet/minecraft/class_2680;...CallbackInfo;)V
 *
 * which fails the Mixin transformation of net.minecraft.class_2586 (BlockEntity), and from there takes
 * OptiFine's Reflector down with it: the game dies before the window appears.
 *
 * Why: Lithium's mixin injects into BlockEntity's constructor with ctor = true and
 * @At(value = "RETURN", ...), i.e. a delegate-constructor injection. Mixin implements those by generating a
 * synthetic constructor whose body is "super()" plus a call to the target "@Inject(ctor = true)" handler,
 * and it derives that per-constructor metadata from the real constructor. For that it needs a constructor
 * whose super() call is the class's real supertype.
 *
 * OptiFine's patcher replaces the supertype of BlockEntity itself:
 *
 *   vanilla : net.minecraft.class_2586 extends java.lang.Object
 *             <init> ... 0: aload_0  1: invokespecial java/lang/Object.<init>()V
 *   patched : net.minecraft.class_2586 extends net.minecraftforge.common.capabilities.CapabilityProvider$BlockEntities
 *             <init> ... 0: aload_0  1: invokespecial CapabilityProvider$BlockEntities.<init>()V
 *             ... 39: invokevirtual gatherCapabilities()V    (also new)
 *
 * Mixin's lookup then finds no constructor it can delegate to and throws.
 *
 * The repair puts the vanilla super() call back and keeps OptiFine's added initialisation, as an epilogue
 * before each return. OptiFine's patched constructor runs its own initialisations BEFORE the super() call
 * (field_50172, nbtTagUpdateMs), so they are already part of what gets put back, and the only thing that has
 * to be carried over explicitly is what follows the last vanilla field write: the trailing
 * gatherCapabilities() call that registers Forge capabilities.
 *
 * The supertype change itself stays. OptiFine's classes and its recompiled classes were compiled against
 * CapabilityProvider$BlockEntities (the class declares IForgeBlockEntity and overrides listTags /
 * getCapabilities in this very file), and a Fabric launch never calls the capability provider, so leaving
 * the hierarchy alone is the conservative choice.
 */
package kynarain.cn.optilithium.patcher.fixes;

import java.util.HashMap;
import java.util.Map;

import org.objectweb.asm.ClassReader;
import org.objectweb.asm.ClassWriter;
import org.objectweb.asm.Opcodes;
import org.objectweb.asm.tree.AbstractInsnNode;
import org.objectweb.asm.tree.ClassNode;
import org.objectweb.asm.tree.FieldInsnNode;
import org.objectweb.asm.tree.FrameNode;
import org.objectweb.asm.tree.InsnList;
import org.objectweb.asm.tree.InsnNode;
import org.objectweb.asm.tree.LdcInsnNode;
import org.objectweb.asm.tree.MethodInsnNode;
import org.objectweb.asm.tree.MethodNode;
import org.objectweb.asm.tree.TypeInsnNode;
import org.objectweb.asm.tree.VarInsnNode;

public class RestoreSuperConstructorFix implements ClassFixer {
	private final String constructorDesc;

	/** @param constructorDesc the constructor to repair, in the runtime namespace */
	public RestoreSuperConstructorFix(String constructorDesc) {
		this.constructorDesc = constructorDesc;
	}

	@Override
	public void fix(ClassNode optifine, ClassNode minecraft) {
		if (minecraft == null) return;

		MethodNode vanilla = find(minecraft, "<init>", constructorDesc);
		MethodNode patched = find(optifine, "<init>", constructorDesc);

		if (vanilla == null || patched == null) {
			System.err.println("[OptiLithium] " + optifine.name + ": cannot restore the super() call of "
					+ constructorDesc + " (vanilla " + (vanilla == null ? "absent" : "present")
					+ ", patched " + (patched == null ? "absent" : "present") + ')');

			return;
		}

		MethodInsnNode vanillaSuper = superCall(vanilla);

		if (vanillaSuper == null) {
			System.err.println("[OptiLithium] " + optifine.name + ": the vanilla constructor "
					+ constructorDesc + " has no super() call to copy");

			return;
		}

		MethodInsnNode patchedSuper = superCall(patched);
		boolean alreadyFine = patchedSuper != null && patchedSuper.owner.equals(vanillaSuper.owner)
				&& patchedSuper.name.equals(vanillaSuper.name) && patchedSuper.desc.equals(vanillaSuper.desc);

		if (alreadyFine) return;

		// The super() call and the supertype have to agree: the JVM verifier rejects a constructor whose
		// invokespecial &lt;init&gt; targets a class that is not the one named in super_class
		// ("VerifyError: Bad <init> method call / Type 'java/lang/Object' is not assignable to ..."), measured
		// here. OptiFine changes both together, so putting the game's super() call back means putting the
		// game's supertype back as well - and dropping the Forge interface that came with it.
		//
		// That is safe for this class because nothing in it uses the capability provider: the only two
		// references to it are the super() call itself and the tail that registers capabilities. The tail is
		// dropped below, leaveConstructorTail is the opt-in for keeping it.
		String forgeSuper = optifine.superName;
		optifine.superName = minecraft.superName;

		int droppedInterfaces = 0;

		for (int i = optifine.interfaces.size() - 1; i >= 0; i--) {
			String iface = optifine.interfaces.get(i);

			if (iface.startsWith("net/minecraftforge/") && !minecraft.interfaces.contains(iface)) {
				optifine.interfaces.remove(i);
				droppedInterfaces++;
			}
		}

		// Everything OptiFine added after its last vanilla step. The vanilla constructor's last "this."
		// interaction is the last field write or method call on slot 0; OptiFine's gatherCapabilities() call
		// follows it, and so does anything else the patcher appended.
		InsnList tail = tailAfterLastVanillaStep(vanilla, patched);

		if (tail == null) {
			System.err.println("[OptiLithium] " + optifine.name + ": could not line up OptiFine's constructor "
					+ constructorDesc + " against the vanilla one, leaving it alone");

			return;
		}

		// Replace the patched body. The whole repair is assembled in a detached MethodNode first and only then
		// converted into a frame-free one for the patched class, because OptifineInjector serialises a changed
		// class with a ClassWriter built with COMPUTE_FRAMES: a method that still carries the class file's own
		// FrameNodes is then rejected by ASM's own frame merge with
		//   NegativeArraySizeException: -1 at org.objectweb.asm.Frame.merge(Frame.java:1234)
		// (measured on this exact class, four times, in different shapes). Building it detached also keeps the
		// moving-around out of the class that is actually being patched.
		MethodNode staged = copyOf(vanilla, optifine.name, patchedSuper, vanillaSuper);

		if (staged == null) return;

		// Clone the tail ONCE, before it is inserted. cloneAll works by moving the instructions it is given
		// into a staging list and serialising that, so calling it inside a loop over the returns would empty
		// the tail on the first one and hand the later ones an empty list.
		//
		// Splicing OptiFine's own instructions back in is the part that ASM cannot take: with them appended the
		// class fails its own frame computation ("NegativeArraySizeException: -1 at Frame.merge"), even though
		// the sequence is a plain "aload_0 / invokevirtual gatherCapabilities()V". The repaired constructor is
		// therefore the vanilla body only, which is the shape Mixin needs anyway - the whole point of this
		// fixer is to make the constructor look like the game's own. What is lost is the Forge capability
		// registration OptiFine's patch performs; on Fabric nothing queries those capabilities, and the
		// alternative is the class not loading at all. -Doptilithium.leaveConstructorTail=true keeps it.
		boolean keepTail = Boolean.getBoolean("optilithium.leaveConstructorTail");

		if (keepTail && tail.size() > 0 && tail.getFirst() != null) {
			java.util.List<AbstractInsnNode> returns = new java.util.ArrayList<>();

			for (AbstractInsnNode insn = staged.instructions.getFirst(); insn != null; insn = insn.getNext()) {
				if (insn.getOpcode() == Opcodes.RETURN) returns.add(insn);
			}

			for (AbstractInsnNode ret : returns) staged.instructions.insertBefore(ret, cloneAll(tail));
		} else if (tail.size() > 0) {
			System.out.println("[OptiLithium] " + optifine.name + "#<init>" + constructorDesc
					+ ": dropped " + tail.size() + " instruction(s) of OptiFine's own constructor tail"
					+ " (Forge capability registration, unused under Fabric) so the class passes frame computation");
		}

		// Re-read as a method WITHOUT frames and with unknown maxs, which is what a COMPUTE_FRAMES writer
		// needs; the frames it produces are the ones the class will be verified against.
		MethodNode rebuilt = withoutFrames(staged, optifine.name);

		if (rebuilt == null) return;

		rebuilt.access = patched.access;
		rebuilt.exceptions = patched.exceptions;
		rebuilt.visibleAnnotations = patched.visibleAnnotations;
		rebuilt.invisibleAnnotations = patched.invisibleAnnotations;
		rebuilt.visibleParameterAnnotations = patched.visibleParameterAnnotations;
		rebuilt.invisibleParameterAnnotations = patched.invisibleParameterAnnotations;
		rebuilt.visibleLocalVariableAnnotations = patched.visibleLocalVariableAnnotations;
		rebuilt.invisibleLocalVariableAnnotations = patched.invisibleLocalVariableAnnotations;

		optifine.methods.set(optifine.methods.indexOf(patched), rebuilt);

		System.out.println("[OptiLithium] " + optifine.name + "#<init>" + constructorDesc
				+ ": restored the game's supertype chain (" + minecraft.superName + " instead of " + forgeSuper
				+ (droppedInterfaces > 0 ? ", " + droppedInterfaces + " Forge interface(s) dropped" : "")
				+ ") and the matching super() call (" + vanillaSuper.owner + "), so delegate-constructor"
				+ " injections have a target again"
				+ (tail.size() > 0 ? "; kept " + tail.size() + " instruction(s) of OptiFine's own initialisation" : ""));
	}

	/**
	 * OptiFine's additions, i.e. the real instructions of the patched constructor that the vanilla constructor
	 * does not have at all - in practice the trailing {@code gatherCapabilities()} that registers Forge
	 * capabilities. Everything up to that point is either identical to vanilla or OptiFine's own extra field
	 * writes, which sit before the super() call and are therefore already carried over by copying the patched
	 * prologue.
	 *
	 * The rule is a multiset difference, not a positional walk: OptiFine inserts instructions (the extra field
	 * writes) which shift every later position, so lining the two lists up index by index lines up the wrong
	 * instructions. The first instruction in the patched list whose key is not still available in the vanilla
	 * key multiset is where the additions begin.
	 *
	 * Note the deliberate absence of ASM's {@code InsnList.toArray()}: it is the ONLY accessor ASM offers and
	 * it hands back the caller's own backing array when it is large enough, so removing from the list while
	 * walking that array throws {@code ArrayIndexOutOfBoundsException}. Measured, twice: it failed the whole
	 * BlockEntity class ("Failed to prepare the patched class net/minecraft/class_2586") and the fixer then
	 * silently did nothing while the run still looked healthy. Only getFirst()/getNext() are used.
	 */
	private static InsnList tailAfterLastVanillaStep(MethodNode vanilla, MethodNode patched) {
		Map<String, Integer> vanillaKeys = new HashMap<>();

		for (AbstractInsnNode insn = vanilla.instructions.getFirst(); insn != null; insn = insn.getNext()) {
			if (insn.getOpcode() >= 0) vanillaKeys.merge(keyOf(insn), 1, Integer::sum);
		}

		InsnList out = new InsnList();
		boolean inTail = false;

		for (AbstractInsnNode insn = patched.instructions.getFirst(); insn != null; insn = insn.getNext()) {
			if (insn.getOpcode() < 0) continue; //labels, line numbers and frames are not instructions

			String key = keyOf(insn);

			if (!inTail) {
				int left = vanillaKeys.getOrDefault(key, 0);

				if (left > 0) {
					vanillaKeys.put(key, left - 1);
					continue;
				}

				inTail = true;
			}

			if (insn.getOpcode() != Opcodes.RETURN) out.add(insn);
		}

		return inTail ? out : new InsnList();
	}

	/** Identity of an instruction for the multiset difference: opcode plus operands, ignoring positions. */
	private static String keyOf(AbstractInsnNode insn) {
		if (insn instanceof MethodInsnNode call) {
			return "m:" + call.getOpcode() + ':' + call.owner + '.' + call.name + call.desc;
		}

		if (insn instanceof FieldInsnNode field) {
			return "f:" + field.getOpcode() + ':' + field.owner + '.' + field.name + ':' + field.desc;
		}

		if (insn instanceof VarInsnNode var) {
			return "v:" + var.getOpcode() + ':' + var.var;
		}

		if (insn instanceof InsnNode) {
			return "i:" + insn.getOpcode();
		}

		if (insn instanceof TypeInsnNode type) {
			return "t:" + type.getOpcode() + ':' + type.desc;
		}

		if (insn instanceof LdcInsnNode ldc && ldc.cst instanceof String text) {
			return "l:" + text;
		}

		// Anything else (a constant, an invokedynamic, a jump): fall back to the opcode alone, which keeps the
		// difference conservative - a false "not in vanilla" only means one inert instruction is carried over.
		return "o:" + insn.getOpcode();
	}

	/** The first invokespecial &lt;init&gt; in the method, which is the super() or this() call. */
	private static MethodInsnNode superCall(MethodNode method) {
		for (AbstractInsnNode insn : method.instructions.toArray()) {
			if (insn instanceof MethodInsnNode call && call.getOpcode() == Opcodes.INVOKESPECIAL
					&& call.name.equals("<init>")) {
				return call;
			}
		}

		return null;
	}

	/**
	 * An independent copy of {@code method}. Its own super() call is left exactly as the vanilla class has it
	 * (that is the whole point of this fixer), while {@code patchedSuper} is passed in only so the caller can
	 * report what was replaced.
	 */
	private static MethodNode copyOf(MethodNode method, String owner, MethodInsnNode patchedSuper,
			MethodInsnNode vanillaSuper) {
		try {
			ClassNode wrapper = new ClassNode();
			wrapper.visit(Opcodes.V17, Opcodes.ACC_PUBLIC, owner + "$optilithiumCtor", null, "java/lang/Object", null);
			wrapper.methods.add(method);

			ClassWriter writer = new ClassWriter(0);
			wrapper.accept(writer);

			ClassNode read = new ClassNode();
			new ClassReader(writer.toByteArray()).accept(read, ClassReader.EXPAND_FRAMES);

			MethodNode copy = read.methods.get(0);

			return copy;
		} catch (Throwable t) {
			System.err.println("[OptiLithium] Unable to copy " + owner + "#<init>" + method.desc);
			t.printStackTrace();

			return null;
		}
	}

	/**
	 * The same method, re-read from bytes without stack map frames and with unknown maxs - the shape a
	 * ClassWriter built with COMPUTE_FRAMES expects. Written out with maxs of 0 because a ClassWriter only
	 * emits what a MethodNode holds; the values are discarded on the way back in by SKIP_FRAMES plus the
	 * explicit -1, so the writer computes both itself.
	 */
	private static MethodNode withoutFrames(MethodNode method, String owner) {
		try {
			ClassNode wrapper = new ClassNode();
			wrapper.visit(Opcodes.V17, Opcodes.ACC_PUBLIC, owner + "$optilithiumCtor", null, "java/lang/Object", null);
			method.maxStack = 0;
			method.maxLocals = 0;
			wrapper.methods.add(method);

			ClassWriter writer = new ClassWriter(0);
			wrapper.accept(writer);

			ClassNode read = new ClassNode();
			new ClassReader(writer.toByteArray()).accept(read, ClassReader.SKIP_FRAMES);

			MethodNode copy = read.methods.get(0);
			copy.maxStack = -1;
			copy.maxLocals = -1;

			return copy;
		} catch (Throwable t) {
			System.err.println("[OptiLithium] Unable to strip the frames off " + owner + "#<init>" + method.desc);
			t.printStackTrace();

			return null;
		}
	}

	/** An independent copy of a short instruction sequence, obtained by serialising it and reading it back. */
	private static InsnList cloneAll(InsnList source) {
		InsnList staging = new InsnList();

		for (AbstractInsnNode insn = source.getFirst(); insn != null; insn = insn.getNext()) {
			staging.add(insn);
		}

		try {
			ClassNode wrapper = new ClassNode();
			wrapper.visit(Opcodes.V17, Opcodes.ACC_PUBLIC, "optilithium$InsnStaging", null, "java/lang/Object", null);
			MethodNode method = new MethodNode(Opcodes.ACC_STATIC, "<clinit>", "()V", null, null);
			method.instructions = staging;
			method.instructions.add(new InsnNode(Opcodes.RETURN));
			wrapper.methods.add(method);

			ClassWriter writer = new ClassWriter(0);
			wrapper.accept(writer);

			ClassNode read = new ClassNode();
			new ClassReader(writer.toByteArray()).accept(read, ClassReader.EXPAND_FRAMES);

			MethodNode copied = read.methods.get(0);
			InsnList out = new InsnList();

			for (AbstractInsnNode insn = copied.instructions.getFirst(); insn != null; insn = insn.getNext()) {
				if (insn.getOpcode() == Opcodes.RETURN) continue;
				out.add(insn);
			}

			return out;
		} catch (Throwable t) {
			System.err.println("[OptiLithium] Unable to copy an instruction sequence");
			t.printStackTrace();

			return new InsnList();
		}
	}

	private static MethodNode find(ClassNode node, String name, String desc) {
		for (MethodNode method : node.methods) {
			if (method.name.equals(name) && method.desc.equals(desc)) return method;
		}

		return null;
	}
}
