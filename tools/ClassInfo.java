import java.io.DataInputStream;
import java.io.FileInputStream;
import java.io.IOException;

/**
 * Prints a class's own name, superclass, interfaces and members from a raw .class file.
 *
 * Needed because javap refuses a file whose name does not match the class inside it, and a class dumped out of
 * an OptiFine cache is exactly that: tools/DumpCacheClass writes net/minecraft/class_1044 to whatever path the
 * caller passes, and "javap class_1044" then fails with a "file does not contain class class_1044" error while
 * still printing a listing - so the failure is easy to miss and the listing easy to misread. This reads the
 * bytes and reports what the file actually declares.
 *
 * Usage: java ClassInfo <file.class>
 */
public final class ClassInfo {
	public static void main(String[] args) throws IOException {
		if (args.length < 1) {
			System.err.println("usage: ClassInfo <file.class>");
			System.exit(1);
		}
		try (DataInputStream in = new DataInputStream(new FileInputStream(args[0]))) {
			if (in.readInt() != 0xCAFEBABE) {
				System.err.println("not a class file");
				System.exit(2);
			}
			in.readUnsignedShort(); // minor
			in.readUnsignedShort(); // major
			int cpCount = in.readUnsignedShort();
			String[] utf8 = new String[cpCount];
			int[] classNameIndex = new int[cpCount];
			for (int i = 1; i < cpCount; i++) {
				int tag = in.readUnsignedByte();
				switch (tag) {
					case 1:
						utf8[i] = in.readUTF();
						break;
					case 7: case 8: case 16: case 19: case 20:
						classNameIndex[i] = in.readUnsignedShort();
						break;
					case 15:
						in.readUnsignedByte();
						in.readUnsignedShort();
						break;
					case 3: case 4: case 9: case 10: case 11: case 12: case 17: case 18:
						in.skipBytes(4);
						break;
					case 5: case 6:
						in.skipBytes(8);
						i++;
						break;
					default:
						throw new IOException("unknown constant pool tag " + tag + " at " + i);
				}
			}
			in.readUnsignedShort(); // access flags
			System.out.println("this  : " + resolve(in.readUnsignedShort(), classNameIndex, utf8));
			System.out.println("super : " + resolve(in.readUnsignedShort(), classNameIndex, utf8));
			int ifaceCount = in.readUnsignedShort();
			for (int i = 0; i < ifaceCount; i++) {
				System.out.println("iface : " + resolve(in.readUnsignedShort(), classNameIndex, utf8));
			}
			int fieldCount = in.readUnsignedShort();
			System.out.println("--- " + fieldCount + " field(s) ---");
			for (int i = 0; i < fieldCount; i++) {
				in.readUnsignedShort();
				System.out.println("  " + utf8[in.readUnsignedShort()] + " " + utf8[in.readUnsignedShort()]);
				skipAttributes(in);
			}
			int methodCount = in.readUnsignedShort();
			System.out.println("--- " + methodCount + " method(s) ---");
			for (int i = 0; i < methodCount; i++) {
				in.readUnsignedShort();
				System.out.println("  " + utf8[in.readUnsignedShort()] + " " + utf8[in.readUnsignedShort()]);
				skipAttributes(in);
			}
		}
	}

	private static String resolve(int index, int[] classNameIndex, String[] utf8) {
		int target = classNameIndex[index];
		return target != 0 ? utf8[target] : "?";
	}

	private static void skipAttributes(DataInputStream in) throws IOException {
		int n = in.readUnsignedShort();
		for (int i = 0; i < n; i++) {
			in.readUnsignedShort();
			in.skipBytes((int) in.readInt());
		}
	}
}
