// The library Voly attaches to a debuggable Android app:
//
//   adb shell cmd activity attach-agent <process> <this.so>=dex=<path>,socket=…,token=…
//
// ART loads it into the running app and calls Agent_OnAttach on the main
// thread. All it does is load the agent's dex file from memory and call
// dev.voly.agent.Bootstrap.start(options); everything else is Java.
//
// Attaching again (a restarted Voly) reuses the classes loaded the first
// time and only hands the new options over.

#include <jni.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <android/log.h>

#define TAG "VolyAgent"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

static jclass g_bootstrap = NULL;

static int clear_exception(JNIEnv *env, const char *what) {
    if (!(*env)->ExceptionCheck(env)) return 0;
    LOGE("%s failed", what);
    (*env)->ExceptionDescribe(env);
    (*env)->ExceptionClear(env);
    return 1;
}

// The agent reads a few platform internals (the list of windows and
// activities, a drawable's stroke). This library is called from platform
// code, which may lift the hidden-API filter for the process; a debuggable
// app is the only kind it can be attached to.
static void allow_hidden_apis(JNIEnv *env) {
    jclass runtime_class = (*env)->FindClass(env, "dalvik/system/VMRuntime");
    if (clear_exception(env, "finding VMRuntime") || runtime_class == NULL) return;
    jmethodID get_runtime = (*env)->GetStaticMethodID(env, runtime_class, "getRuntime", "()Ldalvik/system/VMRuntime;");
    jmethodID set_exemptions =
        (*env)->GetMethodID(env, runtime_class, "setHiddenApiExemptions", "([Ljava/lang/String;)V");
    if (clear_exception(env, "resolving setHiddenApiExemptions") || get_runtime == NULL || set_exemptions == NULL) {
        return;
    }
    jobject runtime = (*env)->CallStaticObjectMethod(env, runtime_class, get_runtime);
    if (clear_exception(env, "VMRuntime.getRuntime") || runtime == NULL) return;
    jclass string_class = (*env)->FindClass(env, "java/lang/String");
    jobjectArray prefixes = (*env)->NewObjectArray(env, 1, string_class, (*env)->NewStringUTF(env, "L"));
    if (clear_exception(env, "building the exemption list") || prefixes == NULL) return;
    (*env)->CallVoidMethod(env, runtime, set_exemptions, prefixes);
    clear_exception(env, "setHiddenApiExemptions");
}

// "dex=/data/…/voly-agent.dex,socket=…" -> "/data/…/voly-agent.dex" (malloc'd)
static char *option_value(const char *options, const char *key) {
    size_t key_length = strlen(key);
    const char *cursor = options;
    while (cursor != NULL && *cursor != '\0') {
        const char *end = strchr(cursor, ',');
        size_t length = end != NULL ? (size_t)(end - cursor) : strlen(cursor);
        if (length > key_length && strncmp(cursor, key, key_length) == 0 && cursor[key_length] == '=') {
            size_t value_length = length - key_length - 1;
            char *value = malloc(value_length + 1);
            if (value == NULL) return NULL;
            memcpy(value, cursor + key_length + 1, value_length);
            value[value_length] = '\0';
            return value;
        }
        cursor = end != NULL ? end + 1 : NULL;
    }
    return NULL;
}

static jclass load_bootstrap(JNIEnv *env, const char *dex_path) {
    FILE *file = fopen(dex_path, "rb");
    if (file == NULL) {
        LOGE("cannot open %s", dex_path);
        return NULL;
    }
    fseek(file, 0, SEEK_END);
    long size = ftell(file);
    fseek(file, 0, SEEK_SET);
    // Deliberately never freed: the runtime may keep reading the dex from it.
    void *bytes = size > 0 ? malloc((size_t)size) : NULL;
    if (bytes == NULL || fread(bytes, 1, (size_t)size, file) != (size_t)size) {
        LOGE("cannot read %s", dex_path);
        fclose(file);
        return NULL;
    }
    fclose(file);

    jobject buffer = (*env)->NewDirectByteBuffer(env, bytes, (jlong)size);
    if (clear_exception(env, "wrapping the dex bytes") || buffer == NULL) return NULL;

    jclass class_loader_class = (*env)->FindClass(env, "java/lang/ClassLoader");
    jmethodID get_system_loader =
        (*env)->GetStaticMethodID(env, class_loader_class, "getSystemClassLoader", "()Ljava/lang/ClassLoader;");
    jobject parent = (*env)->CallStaticObjectMethod(env, class_loader_class, get_system_loader);
    if (clear_exception(env, "ClassLoader.getSystemClassLoader")) return NULL;

    jclass loader_class = (*env)->FindClass(env, "dalvik/system/InMemoryDexClassLoader");
    if (clear_exception(env, "finding InMemoryDexClassLoader") || loader_class == NULL) return NULL;
    jmethodID constructor =
        (*env)->GetMethodID(env, loader_class, "<init>", "(Ljava/nio/ByteBuffer;Ljava/lang/ClassLoader;)V");
    jobject loader = (*env)->NewObject(env, loader_class, constructor, buffer, parent);
    if (clear_exception(env, "loading the agent dex") || loader == NULL) return NULL;

    jmethodID load_class =
        (*env)->GetMethodID(env, class_loader_class, "loadClass", "(Ljava/lang/String;)Ljava/lang/Class;");
    jobject bootstrap = (*env)->CallObjectMethod(
        env, loader, load_class, (*env)->NewStringUTF(env, "dev.voly.agent.Bootstrap"));
    if (clear_exception(env, "loading dev.voly.agent.Bootstrap") || bootstrap == NULL) return NULL;
    return (jclass)(*env)->NewGlobalRef(env, bootstrap);
}

static jint start_agent(JavaVM *vm, const char *options) {
    JNIEnv *env = NULL;
    if ((*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_6) != JNI_OK) {
        if ((*vm)->AttachCurrentThread(vm, &env, NULL) != JNI_OK || env == NULL) {
            LOGE("no JNI environment");
            return JNI_ERR;
        }
    }
    if (options == NULL) options = "";

    if (g_bootstrap == NULL) {
        allow_hidden_apis(env);
        char *dex_path = option_value(options, "dex");
        if (dex_path == NULL) {
            LOGE("no dex= option");
            return JNI_ERR;
        }
        g_bootstrap = load_bootstrap(env, dex_path);
        free(dex_path);
        if (g_bootstrap == NULL) return JNI_ERR;
    }

    jmethodID start = (*env)->GetStaticMethodID(env, g_bootstrap, "start", "(Ljava/lang/String;)V");
    if (clear_exception(env, "resolving Bootstrap.start") || start == NULL) return JNI_ERR;
    (*env)->CallStaticVoidMethod(env, g_bootstrap, start, (*env)->NewStringUTF(env, options));
    if (clear_exception(env, "Bootstrap.start")) return JNI_ERR;
    LOGI("agent started");
    return JNI_OK;
}

JNIEXPORT jint JNICALL Agent_OnAttach(JavaVM *vm, char *options, void *reserved) {
    (void)reserved;
    return start_agent(vm, options);
}

JNIEXPORT jint JNICALL Agent_OnLoad(JavaVM *vm, char *options, void *reserved) {
    (void)reserved;
    return start_agent(vm, options);
}
