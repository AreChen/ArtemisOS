/* ArtemisOS local-display changes to scrcpy 4.1, Apache-2.0. */
package com.genymobile.scrcpy;

/** Pure policy shared by the Android entry point and host-side regression tests. */
public final class ArtemisDisplayPolicy {
    private ArtemisDisplayPolicy() { }

    public static int mirrorFlags() {
        // Android 15 DisplayManager: SECURE | AUTO_MIRROR, deliberately not OWN_CONTENT_ONLY.
        return (1 << 2) | (1 << 4);
    }

    public static void requireRoot(int uid) {
        if (uid != 0) {
            throw new SecurityException("Artemis local secure display requires process-local root; su 0 did not grant it");
        }
    }

    public static boolean mustRelaunch(int uid, boolean alreadyRelaunched) {
        if (uid == 0) {
            return false;
        }
        if (alreadyRelaunched) {
            requireRoot(uid); // Fail instead of recursively spawning su.
        }
        return true;
    }

    public static String[] rootCommand(String[] args) {
        String[] command = new String[args.length + 5];
        command[0] = "su";
        command[1] = "0";
        command[2] = "/system/bin/app_process";
        command[3] = "/";
        command[4] = "com.genymobile.scrcpy.Server";
        System.arraycopy(args, 0, command, 5, args.length);
        return command;
    }
}
