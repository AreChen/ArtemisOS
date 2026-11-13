#include <jni.h>

JNIEXPORT jint JNICALL
Java_internal_artemis_abilab_MainActivity_nativeProbe(JNIEnv *env, jclass type, jint value) {
    (void)env;
    (void)type;
    return value * 3 + 7;
}
