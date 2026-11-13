package com.genymobile.scrcpy;

import java.util.Arrays;

public final class ArtemisDisplayPolicyTest {
    private static void check(boolean value, String message) {
        if (!value) throw new AssertionError(message);
    }
    public static void main(String[] ignored) {
        check(ArtemisDisplayPolicy.mirrorFlags() == ((1 << 2) | (1 << 4)), "secure + auto-mirror, without own-content-only");
        check(ArtemisDisplayPolicy.mustRelaunch(2000, false), "shell must relaunch");
        check(!ArtemisDisplayPolicy.mustRelaunch(0, false), "root must not recurse");
        check(!ArtemisDisplayPolicy.mustRelaunch(0, true), "root child must not recurse");
        boolean denied = false;
        try { ArtemisDisplayPolicy.mustRelaunch(2000, true); } catch (SecurityException expected) { denied = true; }
        check(denied, "su returning shell must fail rather than recursively spawn");
        denied = false;
        try { ArtemisDisplayPolicy.requireRoot(2000); } catch (SecurityException expected) { denied = true; }
        check(denied, "insecure fallback must fail closed");
        ArtemisDisplayPolicy.requireRoot(0);
        String[] arguments = {"4.1", "scid=12345678", "video_bit_rate=4000000"};
        String[] command = ArtemisDisplayPolicy.rootCommand(arguments);
        check(Arrays.equals(Arrays.copyOfRange(command, 0, 5), new String[] {"su", "0", "/system/bin/app_process", "/", "com.genymobile.scrcpy.Server"}), "direct argv bootstrap, no shell interpolation");
        check(Arrays.equals(Arrays.copyOfRange(command, 5, command.length), arguments), "official client arguments survive exactly");
        check(arguments[0].equals("4.1"), "do not change caller arguments");
        System.out.println("PASS secure display policy: flags, root requirement, bootstrap argv, recursion guard");
    }
}
