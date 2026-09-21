/*
 * New in OptiLithium (which is MPL-2.0, see LICENSE.txt). This file has no OptiFabric counterpart.
 *
 * Makes OptiFine's own calls to the capability members harmless once the Forge supertype is gone.
 *
 * THE DEFECT. RestoreSuperConstructorFix puts the game's own supertype back on the class, which is what lets
 * Lithium's delegate-constructor injection work. That also removes the members the class inherited from
 * Forge's capability provider, and OptiFine's recompiled `method_11014` / `method_11007` call one of them
 * through `this`:
 *
 *   [Server thread/ERROR]: Failed to load data for block entity ... at position Block{minecraft:spawner}
 *   java.lang.NoSuchMethodError: '...CapabilityDispatcher net.minecraft.class_2586.getCapabilities()'
 *     at net.minecraft.class_2586.method_11014(class_2586.java:123)
 *
 * One per saved block entity, ~200 per world load, each one dropping that entity's NBT.
 *
 * WHY NOT DELEGATE BACK TO THE SUPERTYPE. That was tried (see ReExposeInheritedMembersFix): adding a method
 * whose body is `invokespecial <forgeSuper>.getCapabilities()` fails verification, because invoking into a
 * class that is no longer in the class's hierarchy is exactly what the verifier refuses.
 *
 * WHAT THIS DOES INSTEAD. The two call sites are null-guarded - the bytecode is
 *
 *   invokevirtual getCapabilities()LCapabilityDispatcher;
 *   ifnull <skip>
 *   ...code that uses the dispatcher...
 *
 * so the result of the call decides whether a block of code runs at all. Replacing the CALL with
 * `aconst_null` therefore makes the following `ifnull` take its skip branch and the capability-dependent
 * block becomes unreachable - which is the truthful outcome: on Fabric there is no capability dispatcher,
 * that is why the value is null on Forge-less installs too, and the guarded block is Forge-only code.
 *
 * Nothing else changes: the instruction count is unchanged which keeps every line number, local variable
 * range and branch offset in the method valid, and the replacement is a single-instruction substitution
 * rather than a rewrite. A class with no such call is untouched.
 */
package kynarain.cn.optilithium.patcher.fixes;

import org.objectweb.asm.Opcodes;
import org.objectweb.asm.tree.AbstractInsnNode;
import org.objectweb.asm.tree.ClassNode;
import org.objectweb.asm.tree.InsnNode;
import org.objectweb.asm.tree.MethodInsnNode;
import org.objectweb.asm.tree.MethodNode;

public class NeutraliseCapabilityCallsFix implements ClassFixer {
	/** The member OptiFine's recompiled code asks its own class for. */
	private final String memberName;

	/** @param memberName the inherited member to neutralise, by its runtime name (e.g. {@code getCapabilities}) */
	public NeutraliseCapabilityCallsFix(String memberName) {
		this.memberName = memberName;
	}

	@Override
	public void fix(ClassNode optifine, ClassNode minecraft) {
		if (minecraft == null) return;

		int replaced = 0;

		for (MethodNode method : optifine.methods) {
			if (method.instructions == null) continue;

			for (AbstractInsnNode insn : method.instructions.toArray()) {
				if (!(insn instanceof MethodInsnNode call)) continue;
				if (call.getOpcode() != Opcodes.INVOKEVIRTUAL) continue;
				if (!call.name.equals(memberName)) continue;

				// Only a self-call can have been inherited from the supertype that was removed. A call on
				// some other object is somebody else's member and must be left alone.
				if (!call.owner.equals(optifine.name) && !call.owner.equals(optifine.superName)) continue;

				// The result must be consumed by an ifnull/ifnonnull immediately after the call, otherwise
				// substituting null would change what the method does rather than which block it skips.
				AbstractInsnNode next = nextReal(call);
				boolean guarded = next != null && (next.getOpcode() == Opcodes.IFNULL || next.getOpcode() == Opcodes.IFNONNULL);

				if (!guarded) {
					System.err.println("[OptiLithium] " + optifine.name + '.' + method.name
							+ ": the call to " + call.owner + '.' + memberName + call.desc
							+ " is not null-guarded, so it is left alone (substituting null would change behaviour)");

					continue;
				}

				// Same instruction count, so every label, line number and branch offset in this method stays
				// valid - the check that decides whether we may do this is above.
				method.instructions.set(call, new InsnNode(Opcodes.ACONST_NULL));
				replaced++;
			}
		}

		if (replaced > 0) {
			System.out.println("[OptiLithium] " + optifine.name + ": neutralised " + replaced
					+ " call(s) to the inherited " + memberName + " - each was null-guarded, so the"
					+ " Forge-only block behind it is now skipped, which is what happens on a Fabric install"
					+ " with or without this mod. Nothing else in the class changed.");
		}
	}

	/** The next instruction that is not a label, line number or frame. */
	private static AbstractInsnNode nextReal(AbstractInsnNode insn) {
		AbstractInsnNode next = insn.getNext();

		while (next != null && next.getOpcode() < 0) next = next.getNext();

		return next;
	}
}
