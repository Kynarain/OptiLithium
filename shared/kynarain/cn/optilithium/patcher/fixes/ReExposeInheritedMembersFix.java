/*
 * New in OptiLithium (which is MPL-2.0, see LICENSE.txt). This file has no OptiFabric counterpart.
 *
 * Re-exposes the members a class got from the supertype that RestoreSuperConstructorFix removes.
 *
 * THE PROBLEM. OptiFine's patcher swaps a class's supertype for a Forge one
 * (net.minecraftforge.common.capabilities.CapabilityProvider$BlockEntities for BlockEntity) and rewrites the
 * constructor's super() call to match. Restoring the game's own supertype is what makes Lithium's
 * delegate-constructor injection work - but it also takes away everything the class inherited from there, and
 * OptiFine's recompiled code calls some of it through `this`. Those call sites then die at runtime:
 *
 *   [Server thread/ERROR]: Failed to load data for block entity ... for block ... at position Block{minecraft:spawner}
 *   java.lang.NoSuchMethodError: 'net.minecraftforge.common.capabilities.CapabilityDispatcher
 *     net.minecraft.class_2586.getCapabilities()'
 *     at net.minecraft.class_2586.method_11014(class_2586.java:123)
 *     at net.minecraft.class_2586.method_58690(class_2586.java:129)
 *     at net.minecraft.class_2586.method_11005(class_2586.java:257)     <- block entity creation
 *
 * Measured on 1.21.11: the world loads, the shader pack compiles 54 programs, and the game never crashes -
 * but 264 server-thread errors are logged while loading saved block entities, each one a block entity whose
 * NBT was dropped instead of read. A title-screen check cannot see any of this.
 *
 * THE FIX. Put the member back on the class itself, delegating to the same place it used to resolve to.
 * The Forge supertype is still there at runtime - it is only the `super_class` entry that changed - so a
 * method can be re-exposed with `invokespecial <forgeSuper>.name(desc)`, which is exactly the call the
 * inherited one would have made. Fields cannot be delegated that way, so a field is re-exposed through an
 * accessor pair instead.
 *
 * WHAT IT COSTS. These members keep working; they are simply no longer inherited. Nothing else about the
 * class changes, and a class with no such member is untouched.
 *
 * WHY NOT JUST LEAVE THE SUPERTYPE ALONE. Because that is the conflict this project exists to fix: with
 * OptiFine's supertype in place, Mixin's delegate-constructor lookup fails for BlockEntity and the whole
 * class - and OptiFine's Reflector with it - fails to load. Measured on every release from 1.20 to 1.21.10.
 */
package kynarain.cn.optilithium.patcher.fixes;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

import org.objectweb.asm.Opcodes;
import org.objectweb.asm.Type;
import org.objectweb.asm.tree.AbstractInsnNode;
import org.objectweb.asm.tree.ClassNode;
import org.objectweb.asm.tree.FieldInsnNode;
import org.objectweb.asm.tree.FieldNode;
import org.objectweb.asm.tree.InsnNode;
import org.objectweb.asm.tree.MethodInsnNode;
import org.objectweb.asm.tree.MethodNode;
import org.objectweb.asm.tree.VarInsnNode;

public class ReExposeInheritedMembersFix implements ClassFixer {
	/** Methods that are members of every class and never worth re-exposing. */
	private static final Set<String> SKIPPED = Set.of("<init>", "<clinit>");

	/**
	 * The supertype RestoreSuperConstructorFix removes, named by the caller rather than read off the class.
	 *
	 * <p>Reading it off {@code optifine.superName} was the first attempt and it silently did nothing: the two
	 * fixers are registered on the same class and run in registration order, so by the time this one runs the
	 * supertype has already been put back to the game's own - {@code forgeSuper} and {@code minecraft.superName}
	 * were then the same string and the "nothing is being removed" early return fired. Naming it explicitly
	 * makes this fixer independent of the other one's ordering, which is worth more than saving an argument.</p>
	 */
	private final String removedSuper;

	public ReExposeInheritedMembersFix(String removedSuper) {
		this.removedSuper = removedSuper;
	}

	@Override
	public void fix(ClassNode optifine, ClassNode minecraft) {
		if (minecraft == null) return;

		String forgeSuper = removedSuper;

		if (forgeSuper == null || forgeSuper.equals(minecraft.superName)) {
			return; // this class never had the supertype, so nothing was removed and nothing can be orphaned
		}

		// Everything this class asks of itself that the game's side does not provide. Keyed by name+desc so a
		// member reached from several places is only re-exposed once.
		Map<String, Member> missing = new LinkedHashMap<>();

		for (MethodNode method : optifine.methods) {
			if (method.instructions == null) continue;

			for (AbstractInsnNode insn : method.instructions.toArray()) {
				if (insn instanceof MethodInsnNode call) {
					if (call.getOpcode() != Opcodes.INVOKEVIRTUAL && call.getOpcode() != Opcodes.INVOKESPECIAL) continue;
					// A constructor call is the super() call the other fixer rewrites, not an inherited member.
					if (SKIPPED.contains(call.name)) continue;
					if (!reachedThroughThisClass(call.owner, optifine, forgeSuper)) continue;
					if (declares(optifine, call.name, call.desc)) continue;
					if (providedBy(minecraft, call.name, call.desc)) continue;

					missing.putIfAbsent("m:" + call.name + call.desc, new Member(call.name, call.desc, false));
				} else if (insn instanceof FieldInsnNode field) {
					if (field.getOpcode() != Opcodes.GETFIELD && field.getOpcode() != Opcodes.PUTFIELD) continue;
					if (!reachedThroughThisClass(field.owner, optifine, forgeSuper)) continue;
					if (declaresField(optifine, field.name, field.desc)) continue;
					if (providedFieldBy(minecraft, field.name, field.desc)) continue;

					missing.putIfAbsent("f:" + field.name + ":" + field.desc, new Member(field.name, field.desc, true));
				}
			}
		}

		if (missing.isEmpty()) return;

		List<String> done = new ArrayList<>();

		for (Member member : missing.values()) {
			try {
				if (member.field) {
					reExposeField(optifine, forgeSuper, member, done);
				} else {
					reExposeMethod(optifine, forgeSuper, member, done);
				}
			} catch (Throwable t) {
				System.err.println("[OptiLithium] " + optifine.name + ": could not re-expose " + member.name
						+ member.desc + " (inherited from " + forgeSuper + "): " + t);
			}
		}

		if (!done.isEmpty()) {
			System.out.println("[OptiLithium] " + optifine.name + ": re-exposed " + done.size()
					+ " member(s) that only the supertype OptiFine installed ("
					+ forgeSuper + ") provides, so OptiFine's own code still resolves them: " + done);
		}
	}

	/**
	 * A method re-exposed as a delegation to the supertype it came from. `invokespecial` is the right opcode:
	 * it is what an inherited call compiles to, and it is what still resolves now that the supertype is only
	 * the runtime superclass and no longer the declared one.
	 */
	private static void reExposeMethod(ClassNode node, String forgeSuper, Member member, List<String> done) {
		String name = member.name + "$optilithiumInherited";

		if (declares(node, name, member.desc)) return;

		MethodNode bridge = new MethodNode(Opcodes.ACC_PUBLIC | Opcodes.ACC_FINAL, name, member.desc, null, null);
		Type[] arguments = Type.getArgumentTypes(member.desc);
		Type returnType = Type.getReturnType(member.desc);
		boolean isStatic = false;

		bridge.instructions.add(new VarInsnNode(Opcodes.ALOAD, 0));

		int slot = 1;
		for (Type argument : arguments) {
			bridge.instructions.add(new VarInsnNode(argument.getOpcode(Opcodes.ILOAD), slot));
			slot += argument.getSize();
		}

		bridge.instructions.add(new MethodInsnNode(Opcodes.INVOKESPECIAL, forgeSuper, member.name, member.desc, false));
		bridge.instructions.add(new InsnNode(returnType.getOpcode(Opcodes.IRETURN)));
		bridge.maxStack = 0;
		bridge.maxLocals = 0;

		node.methods.add(bridge);

		// Point every self-call at the bridge. Leaving the original calls alone would keep them resolving
		// against the declared supertype, which no longer has the member.
		//
		// The bridge itself is skipped, and that is not an optimisation. It is the one place that must keep
		// calling the SUPERCLASS, and the JVM resolves an invokespecial to exactly the class named in the
		// instruction - so rewriting the bridge's own call to point at the bridge made it call itself:
		//
		//   java.lang.StackOverflowError
		//     at net.minecraft.class_2586.getCapabilities$optilithiumInherited(class_2586.java)
		//     at net.minecraft.class_2586.getCapabilities$optilithiumInherited(class_2586.java)   ... x1000
		//
		// The symptom was 132 "Failed to load data for block entity" errors on a world load, one per saved
		// block entity, with the NBT dropped each time. Measured on 1.21.11 and 26.1.2.
		int rewritten = 0;

		for (MethodNode method : node.methods) {
			if (method == bridge) continue;
			if (method.instructions == null) continue;

			for (AbstractInsnNode insn : method.instructions.toArray()) {
				if (!(insn instanceof MethodInsnNode call)) continue;
				if (call.getOpcode() != Opcodes.INVOKEVIRTUAL && call.getOpcode() != Opcodes.INVOKESPECIAL) continue;
				if (!reachedThroughThisClass(call.owner, node, forgeSuper)) continue;
				if (!call.name.equals(member.name) || !call.desc.equals(member.desc)) continue;

				// INVOKESPECIAL is kept as it is: the call already was a self-call, and the bridge is a
				// non-virtual method of this very class, so invokespecial resolves it exactly as the inherited
				// call did. Writing the field `opcode` of an AbstractInsnNode is not possible from here -
				// it is protected in ASM - which is also why the field rewrite below REPLACES the node.
				call.owner = node.name;
				call.name = name;
				rewritten++;
			}
		}

		if (isStatic) return;

		done.add(member.name + member.desc + " (" + rewritten + " call site(s))");
	}

	/**
	 * A field re-exposed through an accessor pair. A field cannot be delegated - there is no opcode that reads
	 * "the field as the superclass sees it" - so the two accessors are what callers are pointed at instead.
	 */
	private static void reExposeField(ClassNode node, String forgeSuper, Member member, List<String> done) {
		String getter = member.name + "$optilithiumGet";
		String setter = member.name + "$optilithiumSet";
		Type fieldType = Type.getType(member.desc);
		String getterDesc = "()" + member.desc;
		String setterDesc = "(" + member.desc + ")V";

		if (!declares(node, getter, getterDesc)) {
			MethodNode method = new MethodNode(Opcodes.ACC_PUBLIC, getter, getterDesc, null, null);
			method.instructions.add(new VarInsnNode(Opcodes.ALOAD, 0));
			method.instructions.add(new FieldInsnNode(Opcodes.GETFIELD, forgeSuper, member.name, member.desc));
			method.instructions.add(new InsnNode(fieldType.getOpcode(Opcodes.IRETURN)));
			method.maxStack = 0;
			method.maxLocals = 0;
			node.methods.add(method);
		}

		if (!declares(node, setter, setterDesc)) {
			MethodNode method = new MethodNode(Opcodes.ACC_PUBLIC, setter, setterDesc, null, null);
			method.instructions.add(new VarInsnNode(Opcodes.ALOAD, 0));
			method.instructions.add(new VarInsnNode(fieldType.getOpcode(Opcodes.ILOAD), 1));
			method.instructions.add(new FieldInsnNode(Opcodes.PUTFIELD, forgeSuper, member.name, member.desc));
			method.instructions.add(new InsnNode(Opcodes.RETURN));
			method.maxStack = 0;
			method.maxLocals = 0;
			node.methods.add(method);
		}

		int rewritten = 0;

		for (MethodNode method : node.methods) {
			if (method.instructions == null) continue;

			for (AbstractInsnNode insn : method.instructions.toArray()) {
				if (!(insn instanceof FieldInsnNode field)) continue;
				if (!reachedThroughThisClass(field.owner, node, forgeSuper)) continue;
				if (!field.name.equals(member.name) || !field.desc.equals(member.desc)) continue;

				if (field.getOpcode() == Opcodes.GETFIELD) {
					// A field instruction node cannot be turned into a method call - its opcode is protected in
					// ASM - so the node is replaced rather than edited.
					method.instructions.set(field, new MethodInsnNode(Opcodes.INVOKEVIRTUAL, node.name, getter, getterDesc, false));
				} else {
					method.instructions.set(field, new MethodInsnNode(Opcodes.INVOKEVIRTUAL, node.name, setter, setterDesc, false));
				}

				rewritten++;
			}
		}

		done.add(member.name + " " + member.desc + " (" + rewritten + " use(s))");
	}

	/**
	 * True when {@code owner} is this class or the supertype that is being removed - the two ways a self-call
	 * can be written. A call into some third class is somebody else's problem.
	 */
	private static boolean reachedThroughThisClass(String owner, ClassNode node, String forgeSuper) {
		return owner.equals(node.name) || owner.equals(forgeSuper);
	}

	private static boolean declares(ClassNode node, String name, String desc) {
		for (MethodNode method : node.methods) {
			if (method.name.equals(name) && method.desc.equals(desc)) return true;
		}

		return false;
	}

	private static boolean declaresField(ClassNode node, String name, String desc) {
		for (FieldNode field : node.fields) {
			if (field.name.equals(name) && field.desc.equals(desc)) return true;
		}

		return false;
	}

	private static boolean providedBy(ClassNode minecraft, String name, String desc) {
		ClassNode node = minecraft;

		while (node != null) {
			if (declares(node, name, desc)) return true;

			node = node.superName == null ? null : GameClasses.read(node.superName);
		}

		return false;
	}

	private static boolean providedFieldBy(ClassNode minecraft, String name, String desc) {
		ClassNode node = minecraft;

		while (node != null) {
			if (declaresField(node, name, desc)) return true;

			node = node.superName == null ? null : GameClasses.read(node.superName);
		}

		return false;
	}

	private static final class Member {
		final String name;
		final String desc;
		final boolean field;

		Member(String name, String desc, boolean field) {
			this.name = name;
			this.desc = desc;
			this.field = field;
		}
	}
}
