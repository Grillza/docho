// The embedded JVM bridge; see include/docho_jvm.h.
#include "docho_jvm.h"
#include "jni/jni.h"

#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef jint (*create_vm_fn)(JavaVM **, void **, void *);

// Work for the JNI thread: a call, or a fetch answer.
typedef struct job {
    struct job *next;
    int kind; // 0 call, 1 fetch result
    int64_t id;
    uint8_t *bytes;
    size_t length;
    uint8_t *body;
    size_t body_length;
    int has_body;
} job;

static JavaVM *vm;
static jclass bridge;
static jmethodID call_method, fetch_result_method;
static oc_jvm_callbacks callbacks;

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t queued = PTHREAD_COND_INITIALIZER;
static job *head, *tail;

// Start-up, done on the JNI thread.
typedef struct {
    const char *const *options;
    int option_count;
    const char *bridge_class;
    const uint8_t *config;
    size_t config_length;
    char *error;
    size_t error_size;
    int result;
    int done;
    pthread_mutex_t lock;
    pthread_cond_t finished;
} start_args;

static create_vm_fn find_create_vm(void) { return (create_vm_fn)dlsym(RTLD_DEFAULT, "JNI_CreateJavaVM"); }

int oc_jvm_available(void) { return find_create_vm() != NULL; }

static uint8_t *copy_array(JNIEnv *env, jbyteArray array, size_t *length) {
    if (!array) { *length = 0; return NULL; }
    jsize size = (*env)->GetArrayLength(env, array);
    uint8_t *bytes = malloc(size > 0 ? (size_t)size : 1);
    if (size > 0) (*env)->GetByteArrayRegion(env, array, 0, size, (jbyte *)bytes);
    *length = (size_t)size;
    return bytes;
}

// Natives the host calls (registered on EmbeddedBridge).

static void JNICALL native_complete(JNIEnv *env, jclass cls, jlong id, jbyteArray response) {
    (void)cls;
    size_t length;
    uint8_t *bytes = copy_array(env, response, &length);
    if (callbacks.complete) callbacks.complete(callbacks.context, id, bytes, length);
    free(bytes);
}

static void JNICALL native_emit(JNIEnv *env, jclass cls, jbyteArray event) {
    (void)cls;
    size_t length;
    uint8_t *bytes = copy_array(env, event, &length);
    if (callbacks.emit) callbacks.emit(callbacks.context, bytes, length);
    free(bytes);
}

static void JNICALL native_fetch(JNIEnv *env, jclass cls, jlong id, jbyteArray meta, jbyteArray body) {
    (void)cls;
    size_t meta_length, body_length;
    uint8_t *meta_bytes = copy_array(env, meta, &meta_length);
    uint8_t *body_bytes = copy_array(env, body, &body_length);
    if (callbacks.fetch) {
        callbacks.fetch(callbacks.context, id, meta_bytes, meta_length, body_bytes, body_length);
    } else {
        free(body_bytes);
    }
    free(meta_bytes);
}

static void JNICALL native_fetch_cancel(JNIEnv *env, jclass cls, jlong id) {
    (void)env; (void)cls;
    if (callbacks.fetch_cancel) callbacks.fetch_cancel(callbacks.context, id);
}

static void set_error(start_args *args, const char *message) {
    if (args->error && args->error_size) snprintf(args->error, args->error_size, "%s", message);
}

static void finish_start(start_args *args, int result) {
    pthread_mutex_lock(&args->lock);
    args->result = result;
    args->done = 1;
    pthread_cond_signal(&args->finished);
    pthread_mutex_unlock(&args->lock);
}

static jbyteArray new_array(JNIEnv *env, const uint8_t *bytes, size_t length) {
    jbyteArray array = (*env)->NewByteArray(env, (jsize)length);
    if (array && length) (*env)->SetByteArrayRegion(env, array, 0, (jsize)length, (const jbyte *)bytes);
    return array;
}

static void run_job(JNIEnv *env, job *work) {
    jbyteArray bytes = new_array(env, work->bytes, work->length);
    if (work->kind == 0) {
        (*env)->CallStaticVoidMethod(env, bridge, call_method, (jlong)work->id, bytes);
    } else {
        jbyteArray body = work->has_body ? new_array(env, work->body, work->body_length) : NULL;
        (*env)->CallStaticVoidMethod(env, bridge, fetch_result_method, (jlong)work->id, bytes, body);
        if (body) (*env)->DeleteLocalRef(env, body);
    }
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionDescribe(env);
        (*env)->ExceptionClear(env);
    }
    if (bytes) (*env)->DeleteLocalRef(env, bytes);
}

// The JNI thread: creates the VM, starts the host, then runs queued jobs for good.
static void *jni_thread(void *arg) {
    start_args *args = arg;
    create_vm_fn create = find_create_vm();
    if (!create) { set_error(args, "No JVM is linked into this app"); finish_start(args, -1); return NULL; }

    JavaVMOption *options = calloc((size_t)args->option_count, sizeof(JavaVMOption));
    for (int i = 0; i < args->option_count; i++) options[i].optionString = (char *)args->options[i];
    JavaVMInitArgs init = {.version = JNI_VERSION_10, .nOptions = args->option_count, .options = options, .ignoreUnrecognized = JNI_FALSE};
    JNIEnv *env = NULL;
    jint created = create(&vm, (void **)&env, &init);
    free(options);
    if (created != JNI_OK || !env) {
        char message[128];
        snprintf(message, sizeof message, "The JVM didn't start (JNI_CreateJavaVM returned %d)", (int)created);
        set_error(args, message);
        finish_start(args, -1);
        return NULL;
    }

    jclass found = (*env)->FindClass(env, args->bridge_class);
    if (!found) {
        (*env)->ExceptionClear(env);
        set_error(args, "The extension host's bridge class isn't on the class path");
        finish_start(args, -1);
        return NULL;
    }
    bridge = (*env)->NewGlobalRef(env, found);
    JNINativeMethod natives[] = {
        {"complete", "(J[B)V", (void *)native_complete},
        {"emit", "([B)V", (void *)native_emit},
        {"fetch", "(J[B[B)V", (void *)native_fetch},
        {"fetchCancel", "(J)V", (void *)native_fetch_cancel},
    };
    jmethodID start = (*env)->GetStaticMethodID(env, bridge, "start", "([B)Ljava/lang/String;");
    call_method = (*env)->GetStaticMethodID(env, bridge, "call", "(J[B)V");
    fetch_result_method = (*env)->GetStaticMethodID(env, bridge, "fetchResult", "(J[B[B)V");
    if (!start || !call_method || !fetch_result_method || (*env)->RegisterNatives(env, bridge, natives, 4) != JNI_OK) {
        (*env)->ExceptionClear(env);
        set_error(args, "The extension host's bridge doesn't match this app");
        finish_start(args, -1);
        return NULL;
    }

    jbyteArray config = new_array(env, args->config, args->config_length);
    jstring failure = (*env)->CallStaticObjectMethod(env, bridge, start, config);
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionDescribe(env);
        (*env)->ExceptionClear(env);
        set_error(args, "The extension host threw while starting");
        finish_start(args, -1);
        return NULL;
    }
    if (failure) {
        const char *text = (*env)->GetStringUTFChars(env, failure, NULL);
        set_error(args, text ? text : "The extension host didn't start");
        if (text) (*env)->ReleaseStringUTFChars(env, failure, text);
        finish_start(args, -1);
        return NULL;
    }
    (*env)->DeleteLocalRef(env, config);
    finish_start(args, 0);

    for (;;) {
        pthread_mutex_lock(&lock);
        while (!head) pthread_cond_wait(&queued, &lock);
        job *work = head;
        head = work->next;
        if (!head) tail = NULL;
        pthread_mutex_unlock(&lock);
        run_job(env, work);
        free(work->bytes);
        free(work->body);
        free(work);
    }
    return NULL;
}

int oc_jvm_start(const void *reserved, const char *const *options, int option_count, const char *bridge_class,
                 const uint8_t *config, size_t config_length, oc_jvm_callbacks given, char *error, size_t error_size) {
    (void)reserved;
    if (vm) { if (error && error_size) snprintf(error, error_size, "The JVM is already running"); return -1; }
    callbacks = given;
    start_args args = {
        .options = options, .option_count = option_count, .bridge_class = bridge_class, .config = config,
        .config_length = config_length, .error = error, .error_size = error_size,
    };
    pthread_mutex_init(&args.lock, NULL);
    pthread_cond_init(&args.finished, NULL);

    pthread_attr_t attributes;
    pthread_attr_init(&attributes);
    // The interpreter recurses deeply (Jsoup, kotlinx.serialization); 8 MB as on a main thread.
    pthread_attr_setstacksize(&attributes, 8 * 1024 * 1024);
    pthread_attr_setdetachstate(&attributes, PTHREAD_CREATE_DETACHED);
    pthread_t thread;
    if (pthread_create(&thread, &attributes, jni_thread, &args) != 0) {
        pthread_attr_destroy(&attributes);
        if (error && error_size) snprintf(error, error_size, "Couldn't start the JVM's thread");
        return -1;
    }
    pthread_attr_destroy(&attributes);
    pthread_mutex_lock(&args.lock);
    while (!args.done) pthread_cond_wait(&args.finished, &args.lock);
    pthread_mutex_unlock(&args.lock);
    pthread_mutex_destroy(&args.lock);
    pthread_cond_destroy(&args.finished);
    return args.result;
}

static int enqueue(int kind, int64_t id, const uint8_t *bytes, size_t length, uint8_t *body, size_t body_length, int has_body) {
    if (!vm) { free(body); return -1; }
    job *work = calloc(1, sizeof(job));
    work->kind = kind;
    work->id = id;
    work->bytes = malloc(length ? length : 1);
    if (length) memcpy(work->bytes, bytes, length);
    work->length = length;
    work->body = body;
    work->body_length = body_length;
    work->has_body = has_body;
    pthread_mutex_lock(&lock);
    if (tail) tail->next = work; else head = work;
    tail = work;
    pthread_cond_signal(&queued);
    pthread_mutex_unlock(&lock);
    return 0;
}

int oc_jvm_call(int64_t id, const uint8_t *bytes, size_t length) { return enqueue(0, id, bytes, length, NULL, 0, 0); }

int oc_jvm_fetch_result(int64_t id, const uint8_t *meta, size_t meta_length, uint8_t *body, size_t body_length) {
    return enqueue(1, id, meta, meta_length, body, body_length, body != NULL);
}
