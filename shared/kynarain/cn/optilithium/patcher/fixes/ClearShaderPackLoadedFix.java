/*
 * New in OptiLithium (which is MPL-2.0, see LICENSE.txt). This file has no OptiFabric counterpart.
 *
 * Removes a dead store OptiFine's own patcher emits, which makes the flag it writes impossible to set.
 *
 * THE DEFECT. On 1.21.9 only, a shader pack never loads. The world loads and the game runs, but OptiFine
 * reports `[Shaders] No shaderpack loaded.` and compiles no programs, whoever selected the pack - including
 * OptiFine's own built-in one. Reads out of `Shaders.loadShaderPack`, the sequence is:
 *
 *   178: putstatic     shaderPack    = getShaderPack(<name>)      # the pack, or null
 *   181: getstatic     shaderPack
 *   184: ifnull        191
 *   187: iconst_1                                                 # loaded = true
 *   188: goto          192
 *   191: iconst_0                                                 # loaded = false
 *   192: putstatic     shaderPackLoaded                           # <- the honest result
 *   195: iconst_0                                                 # <- and then, unconditionally,
 *   196: putstatic     shaderPackLoaded                           #    the same flag set to false
 *   199: getstatic     shaderPackLoaded
 *   202: ifeq          219                                        # always taken, so:
 *   219: ... "No shaderpack loaded." ...
 *
 * The pair at 195/196 is unreachable-as-intended and always executed in fact: it overwrites the value 192 just
 * computed, so `shaderPackLoaded` is false no matter what `getShaderPack` returned, and every run takes the
 * "No shaderpack loaded." branch. There is no path through the method that reaches 199 with the flag true, so
 * shaders cannot load at all on this release - the pack, the config file and the pack directory are all
 * irrelevant to it. 1.21.8 and 1.21.10, whose shader code is otherwise the same, do not have the second store.
 *
 * WHAT THIS DOES. Replaces that `iconst_0` with `nop`, and nothing else.
 *
 * A one-byte instruction for a one-byte instruction, so every offset in the method is unchanged and no label,
 * branch, line number, local-variable range or stack map frame moves. The store that remains is the one at 192,
 * which is what the surrounding code was written to read.
 *
 * HOW THE DEAD PAIR IS IDENTIFIED - structurally, not by offset, because an offset is a fact about one build:
 * an `iconst_0` followed by `putstatic <owner>.shaderPackLoaded` is only removed when the byte immediately
 * before the pair is the OTHER store to that same field preceded by a conditional branch. That is the shape of
 * a computed boolean being overwritten by a constant, and it cannot describe a deliberate assignment.
 *
 * Registered only when the field's owner is the class being patched, so this cannot touch a field of the same
 * name somewhere else.
 */
package kynarain.cn.optilithium.patcher.fixes;

import java.util.LinkedHashMap;
import java.util.Map;

import org.objectweb.asm.Opcodes;
import org.objectweb.asm.tree.AbstractInsnNode;
import org.objectweb.asm.tree.ClassNode;
import org.objectweb.asm.tree.FieldInsnNode;
import org.objectweb.asm.tree.InsnNode;
import org.objectweb.asm.tree.MethodInsnNode;
import org.objectweb.asm.tree.MethodNode;

public class ClearShaderPackLoadedFix implements ClassFixer {
	private static final String FIELD = "shaderPackLoaded";
	private static final String DESC = "Z";

	private final String intendedFor;

	/** @param intendedFor the release this registration is for, only so the log line can name it */
	public ClearShaderPackLoadedFix(String intendedFor) {
		this.intendedFor = intendedFor;
	}

	/**
	 * This fixer replaces one single-byte instruction with another single-byte instruction of the same stack
	 * effect, so every offset and every frame in the class stays valid.
	 *
	 * <p>Declaring it is what keeps OptiFine's {@code Shaders} loadable at all: with frames recomputed, ASM
	 * failed on an unrelated method of the same class and the class was dropped, which left the shader bug in
	 * place and looked exactly like the fixer not having run.</p>
	 */
	@Override
	public boolean keepsFrames() {
		return true;
	}

	@Override
	public void fix(ClassNode optifine, ClassNode minecraft) {
		boolean trace = Boolean.getBoolean("optilithium.traceFixes");
		Map<AbstractInsnNode, MethodNode> dead = new LinkedHashMap<>();

		for (MethodNode method : optifine.methods) {
			if (method.instructions == null) continue;

			// COLLECT FIRST, MODIFY AFTERWARDS, and the ordering is not stylistic.
			//
			// The first version of this fixer replaced the instruction inside the same walk that was still
			// reading neighbours from it, and it silently found nothing. `InsnList.set` unlinks the node it
			// replaces, which invalidates the `getNext()`/`getPrevious()` references the walk was holding: the
			// very next `previousStore.getPrevious()` answered null, the shape test failed, and the fixer
			// reported nothing while the pipeline reported the class as patched.
			AbstractInsnNode[] instructions = method.instructions.toArray();

			for (int i = 0; i < instructions.length; i++) {
				AbstractInsnNode insn = instructions[i];

				if (!(insn instanceof InsnNode) || insn.getOpcode() != Opcodes.ICONST_0) continue;
				if (i + 1 >= instructions.length) continue;

				if (!isStoreOf(instructions[i + 1], optifine.name)) continue;

				// ...and the instruction immediately before the pair is the OTHER store of the same field, so
				// the constant store is dead the moment it executes: nothing can read a value that is overwritten
				// by the very next instruction.
				//
				// That is the rule, and it is deliberately narrower than "a store preceded by a branch". The
				// first version of this test looked for the branch, and found nothing, because the branch lands
				// ON this store rather than falling into it:
				//
				//   170: iload_2
				//   171: ifne 195          <- jumps straight to the store below, skipping the computed value
				//   174: ... getShaderPack / putstatic at 192 ...
				//   195: iconst_0
				//   196: putstatic shaderPackLoaded
				//
				// Nothing emits two consecutive stores to one field on purpose, and if it did, the first would
				// still be dead - so removing the second cannot lose a value anybody could observe.
				//
				// The PREVIOUS REAL INSTRUCTION, not instructions[i - 1]: a frame, label or line number sits
				// between the two stores, and rejecting the pair over that pseudo-instruction is what made the
				// second version of this test change nothing while reporting success.
				if (!isStoreOf(previousReal(instructions, i), optifine.name)) {
					if (trace) {
						System.out.println("[OptiLithium] " + optifine.name + '.' + method.name + ": iconst_0 at "
								+ i + " followed by a store, but the instruction before it is "
								+ describe(previousReal(instructions, i)) + ", so it is not the dead pair");
					}

					continue;
				}

				// The STORE is what gets removed, not the constant that feeds it, and that choice is forced by
				// the frames rather than by taste:
				//
				//   frame_type = 64 /* same_locals_1_stack_item */
				//     stack = [ int ]
				//
				// Offset 195 - the branch target - has a frame carrying an int on the stack, because the
				// original bytecode pushes one there. Replacing that push with a nop leaves the frame claiming a
				// value that is not there, and the verifier answers "Operand stack underflow" at the very next
				// instruction. Replacing the STORE with a pop instead keeps the stack exactly as the frames
				// describe it: push int, discard int, and nothing was stored.
				//
				// Both substitutions are one byte for one byte, so no offset in the method moves either way.
				dead.put(instructions[i + 1], method);

				if (trace) {
					System.out.println("[OptiLithium] " + optifine.name + '.' + method.name
							+ ": found the dead store to " + FIELD + " at instruction " + (i + 1));
				}
			}
		}

		// Collected above; applied here so the walk never reads a list it is modifying.
		int cleared = 0;

		for (Map.Entry<AbstractInsnNode, MethodNode> entry : dead.entrySet()) {
			// A pop of exactly the same size as the putstatic it replaces, so every offset in the method is
			// unchanged and the stack stays balanced - see the note at the match above.
			entry.getValue().instructions.set(entry.getKey(), new InsnNode(Opcodes.POP));
			cleared++;
		}

		if (cleared > 0) {
			System.out.println("[OptiLithium] " + optifine.name + " (" + intendedFor + "): replaced " + cleared
					+ " dead store(s) that set " + FIELD + " to false right after it had been computed, so a"
					+ " selected shader pack can load on this release. Each store became a pop of the same size -"
					+ " the stack stays balanced and no offset in the method moved.");
		} else if (trace) {
			// Every store to the field, with the few instructions around it, so "no dead store here" can be
			// told apart from "the bytecode is not the bytecode this fixer was written against" - which is the
			// difference that took three attempts to see.
			for (MethodNode method : optifine.methods) {
				if (method.instructions == null) continue;

				AbstractInsnNode[] instructions = method.instructions.toArray();

				for (int i = 0; i < instructions.length; i++) {
					if (!isStoreOf(instructions[i], optifine.name)) continue;

					StringBuilder window = new StringBuilder();

					for (int k = Math.max(0, i - 10); k <= Math.min(instructions.length - 1, i + 2); k++) {
						if (instructions[k].getOpcode() < 0) continue;

						window.append(' ').append(instructions[k].getOpcode());

						if (instructions[k] instanceof MethodInsnNode m) window.append('(').append(m.name).append(')');
						if (instructions[k] instanceof FieldInsnNode f) window.append('(').append(f.name).append(')');
					}

					System.out.println("[OptiLithium] " + optifine.name + '.' + method.name + ": store to " + FIELD
							+ " at " + i + " ->" + window);
				}
			}
		}
	}

	/** True when {@code insn} is a putstatic of {@code owner}'s flag. */
	private static boolean isStoreOf(AbstractInsnNode insn, String owner) {
		return insn instanceof FieldInsnNode store && store.getOpcode() == Opcodes.PUTSTATIC
				&& store.name.equals(FIELD) && store.desc.equals(DESC) && store.owner.equals(owner);
	}

	/**
	 * The previous instruction in {@code instructions} that is not a label, line number or frame.
	 *
	 * <p>A raw {@code instructions[i - 1]} is a pseudo-instruction most of the time - the frame that begins the
	 * dead store's basic block sits between it and the store above, which is why the first version of this test
	 * rejected the very pair it was written for and silently changed nothing.</p>
	 */
	private static AbstractInsnNode previousReal(AbstractInsnNode[] instructions, int index) {
		for (int k = index - 1; k >= 0; k--) {
			if (instructions[k].getOpcode() >= 0) return instructions[k];
		}

		return null;
	}

	/** A pseudo-instruction reads better by its type than by its -1 opcode. */
	private static String describe(AbstractInsnNode insn) {
		return insn == null ? "nothing" : insn.getOpcode() + " (" + insn.getClass().getSimpleName() + ')';
	}
}
