/*
 * New in OptiLithium (which is MPL-2.0, see LICENSE.txt). This file has no OptiFabric counterpart.
 *
 * Initialises the multi-texture id OptiFine adds to GlTexture, which OptiFine's own shader code assumes is set.
 *
 * THE DEFECT. With a shader pack selected, 1.21.6 and newer die during game initialisation, before the title
 * screen, on the first dynamic texture the client creates:
 *
 *   java.lang.NullPointerException: Cannot read field "norm" because "multiTex" is null
 *     at net.optifine.shaders.ShadersTex.initDynamicTextureNS(ShadersTex.java:322)
 *     at net.minecraft.client.renderer.texture.DynamicTexture.method_71142(DynamicTexture.java:56)
 *     at net.minecraft.client.renderer.texture.DynamicTexture.<init>(DynamicTexture.java:32)
 *     at net.minecraft.client.renderer.texture.TextureManager.<init>(TextureManager.java:53)
 *
 * The mechanism, read out of the bytecode:
 *
 *   1. OptiFine's patcher adds a `public net.optifine.shaders.MultiTexID multiTex` field to the GL texture class
 *      together with `getMultiTexID()` / `setMultiTexID()`. The getter returns that field and nothing else; the
 *      setter writes it. NOTHING initialises it;
 *   2. `ShadersTex.initDynamicTextureNS` obtains the id through the virtual `getMultiTexID()`. That call is
 *      dispatched on a DynamicTexture and resolves up the hierarchy, so it does NOT reach the GL texture's
 *      own override - it reaches the one on AbstractTexture, which forwards to the GpuTexture the texture
 *      holds, whose stub returns null;
 *   3. `initDynamicTextureNS` dereferences the result immediately (`multiTex.norm`), so the client dies.
 *
 * WHAT THIS DOES, and what it deliberately does NOT.
 *
 * It initialises the field in the constructors of the class that declares it: three instructions after each
 * `super()` call, calling the class's own getter and discarding the result, with the getter rewritten to
 * allocate and cache the id on first use. From then on the field is set, the getter returns a real id, and
 * every caller in the hierarchy - including OptiFine's - gets a non-null value.
 *
 * THREE OTHER DESIGNS WERE MEASURED AND ALL FAILED. They are recorded here because each one looks reasonable
 * and each one costs a full launch to rule out:
 *
 *   - delegating the getter to OptiFine's own static helper `ShadersTex.getMultiTexID(<texture>)`, which does
 *     exactly this lazily. It takes the GAME's texture class, not GpuTexture, so a literal descriptor is wrong
 *     for most releases: the JVM answers NoSuchMethodError for one variant and the verifier answers
 *     "Type integer is not assignable to GpuTexture" for another. Reading the real signature out of OptiFine's
 *     jar fixes that, and then the client dies with StackOverflowError, because the helper's own lazy path
 *     calls the getter first and the getter calls the helper - straight into each other, forever;
 *   - rewriting the four calls INSIDE OptiFine's ShadersTex to read the field directly, which is what breaks
 *     that recursion. That fails too, but on a different axis: three of those calls are dispatched on a
 *     DynamicTexture, and a DynamicTexture is not a GL texture, so the read dies with
 *     "class net.minecraft.class_1043 cannot be cast to class net.minecraft.class_10868". Only the fourth call,
 *     inside the helper itself, ever has a GL texture in hand;
 *   - allocating the id here with a written-out MultiTexID constructor. That constructor is `(int,int,int)`
 *     through 1.21.7 and takes three GL textures from 1.21.8, so the written-out form produced
 *     "NoSuchMethodError: 'void net.optifine.shaders.MultiTexID.<init>(int, int, int)'" on 1.21.8 and 1.21.9.
 *     The constructor is therefore read from OptiFine's mapped jar (see findMultiTexCtor) and the matching
 *     allocation is emitted.
 *
 * The three instructions appended after `super()` are marker-free and referenced by nothing else, so no label,
 * line number or branch offset moves. The stack is balanced (`aload_0; invoke; pop`), so no frame is needed at
 * that point either. A class that does not declare the OptiFine field is left untouched.
 *
 * Measured: without this, 1.21.6 crashes during game initialisation and never reaches the title screen, let
 * alone a world. See docs/IN_WORLD_VERIFICATION.md.
 */
package kynarain.cn.optilithium.patcher.fixes;

import java.io.File;
import java.io.InputStream;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;

import org.objectweb.asm.ClassReader;
import org.objectweb.asm.Opcodes;
import org.objectweb.asm.tree.AbstractInsnNode;
import org.objectweb.asm.tree.ClassNode;
import org.objectweb.asm.tree.FieldInsnNode;
import org.objectweb.asm.tree.FieldNode;
import org.objectweb.asm.tree.InsnList;
import org.objectweb.asm.tree.InsnNode;
import org.objectweb.asm.tree.MethodInsnNode;
import org.objectweb.asm.tree.MethodNode;
import org.objectweb.asm.tree.TypeInsnNode;
import org.objectweb.asm.tree.VarInsnNode;

import kynarain.cn.optilithium.mod.OptilithiumSetup;

public class InitMultiTexIdFix implements ClassFixer {
	/** OptiFine's own type, so all three descriptors here are the same on every line and need no mapping. */
	private static final String MULTI_TEX_OWNER = "net/optifine/shaders/MultiTexID";
	private static final String MULTI_TEX_DESC = "L" + MULTI_TEX_OWNER + ";";

	/** The field OptiFine's patcher adds, and the accessor that reads it. */
	private static final String FIELD = "multiTex";
	private static final String GETTER = "getMultiTexID";

	/** The private synthetic method this fixer adds to back the getter. Namespaced so it cannot collide. */
	private static final String MULTI_TEX_HELPER = "optilithium$multiTex";

	/** OptiFine's GL id getter, which is what it keys its own id map by. Public and stable in every build. */
	private static final String GL_ID = "method_68427";
	private static final String GL_ID_DESC = "()I";

	/** The class whose MultiTexID constructor this fixer builds against. Only its name is needed. */
	private static final String HELPER_OWNER = "net/optifine/shaders/ShadersTex";

	private final String intendedFor;

	/** @param intendedFor the release this registration is for, only so the log line can name it */
	public InitMultiTexIdFix(String intendedFor) {
		this.intendedFor = intendedFor;
	}

	@Override
	public void fix(ClassNode optifine, ClassNode minecraft) {
		// Every early return below is silent by default, and a fixer that decides not to act is indistinguishable
		// from one that was never handed the class. This switch is what told the two apart for 1.21.6, where the
		// registration never matched and nothing anywhere said so.
		boolean trace = Boolean.getBoolean("optilithium.traceFixes");

		if (minecraft == null) {
			if (trace) System.out.println("[OptiLithium] " + optifine.name + ": " + name() + " skipped, no game class");

			return;
		}

		boolean hasField = false;

		for (FieldNode field : optifine.fields) {
			if (field.name.equals(FIELD) && field.desc.equals(MULTI_TEX_DESC)) {
				hasField = true;
				break;
			}
		}

		// No field means OptiFine did not patch this class, or patched it differently on this release. Both are
		// reasons to do nothing: adding state where OptiFine already has working state would replace one
		// assumption with another.
		if (!hasField) {
			if (trace) System.out.println("[OptiLithium] " + optifine.name + ": no " + FIELD + MULTI_TEX_DESC + " field");

			return;
		}

		MethodNode getter = null;
		MethodNode glId = null;

		for (MethodNode method : optifine.methods) {
			if (method.name.equals(GETTER) && method.desc.equals("()" + MULTI_TEX_DESC)) getter = method;
			else if (method.name.equals(GL_ID) && method.desc.equals(GL_ID_DESC)) glId = method;
		}

		if (getter == null) {
			System.err.println("[OptiLithium] " + optifine.name + " has OptiFine's " + FIELD
					+ " field but no " + GETTER + "(), so its texture ids cannot be initialised here");

			return;
		}

		if (glId == null) {
			// Kept as a canary rather than as something the emitted code needs. It is the accessor OptiFine's
			// own id bookkeeping is built around, so a class that does not have it is not the class this fixer
			// was written for - and proceeding on that assumption is how a fixer reports success and the client
			// crashes anyway.
			System.err.println("[OptiLithium] " + optifine.name + " has OptiFine's " + FIELD + " field but no "
					+ GL_ID + "(), so it is left as it is (" + GETTER + "() would return null)");

			return;
		}

		if (isAlreadyFixed(optifine, getter)) return; // Fixers run once, but a second pass must not add a second helper.

		// How OptiFine's MultiTexID is built on this release, read from OptiFine's own jar: the constructor is
		// (int,int,int) through 1.21.7 and takes three GL textures from 1.21.8, so it cannot be written out once.
		String ctor = findMultiTexCtor();

		if (ctor == null) {
			System.err.println("[OptiLithium] " + optifine.name + ": " + MULTI_TEX_OWNER
					+ "'s constructor could not be read from OptiFine's jar, so the ids cannot be allocated here");

			return;
		}

		rewriteGetter(getter, optifine.name, ctor);
		addHelper(optifine, ctor);
		int initialised = initialiseInConstructors(optifine);

		System.out.println("[OptiLithium] " + optifine.name + " (" + intendedFor + "): OptiFine's " + FIELD
				+ " field was never initialised, so " + GETTER + "() returned null and its own shader code"
				+ " dereferenced it during game start. The getter now allocates the id on first use"
				+ " (new " + MULTI_TEX_OWNER + " " + ctor + ", cached by GL texture id) and " + initialised
				+ " constructor(s) call it after super(), so the field is set from the moment a texture exists.");
	}

	private String name() {
		return getClass().getSimpleName();
	}

	/**
	 * The descriptor of OptiFine's {@code MultiTexID} constructor, read from OptiFine's mapped jar.
	 *
	 * <p>Read rather than written out because it CHANGED: {@code (III)V} through 1.21.7, and three GL textures
	 * from 1.21.8. The written-out form produced</p>
	 *
	 * <pre>NoSuchMethodError: 'void net.optifine.shaders.MultiTexID.<init>(int, int, int)'</pre>
	 *
	 * <p>on 1.21.8 and 1.21.9 - a hard failure at the first dynamic texture, after the fixer had reported
	 * success. The jar is the authority: the class is declared in it, already remapped into the running
	 * namespace, and reading it needs no class loading and cannot be thrown off by a missing mapping.</p>
	 */
	private static String findMultiTexCtor() {
		File mappedJar = OptilithiumSetup.optifineRuntimeJar;

		if (mappedJar == null || !mappedJar.isFile()) return null;

		try (ZipFile zip = new ZipFile(mappedJar)) {
			ZipEntry entry = zip.getEntry(MULTI_TEX_OWNER + ".class");

			if (entry == null) return null;

			ClassNode node = new ClassNode();

			try (InputStream in = zip.getInputStream(entry)) {
				new ClassReader(in).accept(node, ClassReader.SKIP_CODE | ClassReader.SKIP_DEBUG | ClassReader.SKIP_FRAMES);
			}

			for (MethodNode method : node.methods) {
				if (method.name.equals("<init>")) return method.desc;
			}
		} catch (Throwable t) {
			System.err.println("[OptiLithium] could not read " + MULTI_TEX_OWNER + " out of the OptiFine jar: " + t);
		}

		return null;
	}

	/** True when this class already has the generated helper, so a second pass changes nothing. */
	private static boolean isAlreadyFixed(ClassNode owner, MethodNode getter) {
		// The METHOD is what must not be added twice: two methods with the same name and descriptor are a
		// ClassFormatError, which takes the client down before anything can report why.
		for (MethodNode method : owner.methods) {
			if (method.name.equals(MULTI_TEX_HELPER) && method.desc.equals("()" + MULTI_TEX_DESC)) return true;
		}

		// Iterated through toArray(), never by walking getNext().
		//
		// A getNext() walk here was an infinite loop on 1.21.6 and it cost a whole run: the client sat at 100%
		// of one core for eight minutes inside this method, the pipeline never printed "Prepared N patched
		// classes", and the harness reported "Prepared -" - a hang that looks like a slow first patch rather
		// than a bug, because nothing crashes and no error is written. ASM's own toArray() walks the same list
		// correctly, so every traversal in this class goes through it.
		if (getter.instructions != null) {
			for (AbstractInsnNode insn : getter.instructions.toArray()) {
				if (insn instanceof MethodInsnNode call && call.name.equals(MULTI_TEX_HELPER)) return true;
			}
		}

		return false;
	}

	private void rewriteGetter(MethodNode getter, String owner, String ctor) {
		InsnList body = new InsnList();
		body.add(new VarInsnNode(Opcodes.ALOAD, 0));
		body.add(new MethodInsnNode(Opcodes.INVOKEVIRTUAL, owner, MULTI_TEX_HELPER, "()" + MULTI_TEX_DESC, false));
		body.add(new InsnNode(Opcodes.ARETURN));

		getter.instructions = body;

		// Left unset on purpose so the frame-computing writer derives both. Writing the values that fit this body
		// is only correct until somebody edits it, and a wrong maxStack is a VerifyError.
		getter.maxStack = 0;
		getter.maxLocals = 0;
		getter.tryCatchBlocks = new java.util.ArrayList<>();
		getter.localVariables = null;
		getter.visibleLocalVariableAnnotations = null;
		getter.invisibleLocalVariableAnnotations = null;
	}

	/**
	 * Adds the private helper that allocates the id on first use.
	 *
	 * <pre>
	 * private MultiTexID optilithium$multiTex() {
	 *     MultiTexID id = this.multiTex;
	 *     if (id != null) return id;
	 *     id = new MultiTexID(&lt;allocation&gt;);   // (III) or (GlTexture,GlTexture,GlTexture)
	 *     this.multiTex = id;
	 *     return id;
	 * }
	 * </pre>
	 *
	 * <p>Writing the field is what keeps OptiFine's own {@code deleteTextures} honest: it deletes the secondary
	 * textures through this field and only consults its own map when the field is already null, so a getter that
	 * handed out an id while leaving the field unset would leak two GL textures per dynamic texture.</p>
	 */
	private void addHelper(ClassNode owner, String ctor) {
		boolean glBased = ctor.startsWith("(L");

		MethodNode helper = new MethodNode(Opcodes.ACC_PRIVATE | Opcodes.ACC_SYNTHETIC, MULTI_TEX_HELPER,
				"()" + MULTI_TEX_DESC, null, null);
		InsnList code = helper.instructions;

		code.add(new VarInsnNode(Opcodes.ALOAD, 0));
		code.add(new FieldInsnNode(Opcodes.GETFIELD, owner.name, FIELD, MULTI_TEX_DESC));

		org.objectweb.asm.tree.LabelNode existing = new org.objectweb.asm.tree.LabelNode();
		code.add(new InsnNode(Opcodes.DUP));
		code.add(new org.objectweb.asm.tree.JumpInsnNode(Opcodes.IFNONNULL, existing));

		code.add(new InsnNode(Opcodes.POP)); // the null just tested
		code.add(new TypeInsnNode(Opcodes.NEW, MULTI_TEX_OWNER));
		code.add(new InsnNode(Opcodes.DUP));

		if (glBased) {
			// 1.21.8 and newer: three GL textures, and the one to hand over is this texture itself.
			for (int i = 0; i < 3; i++) code.add(new VarInsnNode(Opcodes.ALOAD, 0));
		} else {
			// Through 1.21.7: three GL ids, and GL11.glGenTextures() rather than the texture's own id.
			//
			// The texture's OWN id is 0 at this point - the field is set after `super()` and the GL texture is
			// created later, in the subclass's own body - and OptiFine checks the value:
			//
			//   [Shaders] Error : MultiTexID.base mismatch: 0, texid: 2
			//
			// Using glGenTextures() three times gives three non-zero ids, which is what the game's own
			// AbstractTexture path ends up with and what OptiFine's static helper does when it has a real id
			// in hand. The GL_ID parameter is only used to learn the descriptor now.
			for (int i = 0; i < 3; i++) {
				code.add(new MethodInsnNode(Opcodes.INVOKESTATIC, "org/lwjgl/opengl/GL11", "glGenTextures", "()I", false));
			}
		}

		code.add(new MethodInsnNode(Opcodes.INVOKESPECIAL, MULTI_TEX_OWNER, "<init>", ctor, false));
		code.add(new InsnNode(Opcodes.DUP));
		code.add(new VarInsnNode(Opcodes.ALOAD, 0));
		code.add(new InsnNode(Opcodes.SWAP));
		code.add(new FieldInsnNode(Opcodes.PUTFIELD, owner.name, FIELD, MULTI_TEX_DESC));

		code.add(existing); // stack: the id, from either path
		code.add(new InsnNode(Opcodes.ARETURN));

		helper.maxStack = 0;
		helper.maxLocals = 0;

		owner.methods.add(helper);
	}

	/** Appends {@code this.getMultiTexID();} after every constructor's {@code super()} call. */
	private static int initialiseInConstructors(ClassNode owner) {
		int done = 0;

		for (MethodNode method : owner.methods) {
			if (!method.name.equals("<init>") || method.instructions == null) continue;

			AbstractInsnNode superCall = findSuperCall(method, owner.superName);

			if (superCall == null) continue;

			InsnList injected = new InsnList();
			injected.add(new VarInsnNode(Opcodes.ALOAD, 0));
			injected.add(new MethodInsnNode(Opcodes.INVOKEVIRTUAL, owner.name, GETTER, "()" + MULTI_TEX_DESC, false));
			injected.add(new InsnNode(Opcodes.POP));

			method.instructions.insert(superCall, injected);
			done++;
		}

		return done;
	}

	/** The {@code super()} call of a constructor: the first invokespecial of an {@code <init>} on the supertype. */
	private static AbstractInsnNode findSuperCall(MethodNode constructor, String superName) {
		if (constructor.instructions == null) return null;

		for (AbstractInsnNode insn : constructor.instructions.toArray()) {
			if (insn instanceof MethodInsnNode call && call.getOpcode() == Opcodes.INVOKESPECIAL
					&& call.name.equals("<init>") && call.owner.equals(superName)) {
				return insn;
			}
		}

		return null;
	}
}
