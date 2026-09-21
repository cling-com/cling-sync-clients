// JNI entry point for the browse module, mirroring bridge.go.
//
// The params and the result cross JNI as UTF-8 byte arrays, not jstrings:
// JNI's string functions use modified UTF-8, which mangles characters
// outside the BMP (emoji in file names or passphrases).

package main

/*
#include "../tools/android-sdk/ndk/jni-headers/jni.h"
#include <stdlib.h>

static const char* browse_get_string(JNIEnv *env, jstring str) {
    return (*env)->GetStringUTFChars(env, str, NULL);
}

static void browse_release_string(JNIEnv *env, jstring str, const char *chars) {
    (*env)->ReleaseStringUTFChars(env, str, chars);
}

static jsize browse_array_length(JNIEnv *env, jbyteArray array) {
    return (*env)->GetArrayLength(env, array);
}

static void browse_get_bytes(JNIEnv *env, jbyteArray array, jsize len, void *buf) {
    (*env)->GetByteArrayRegion(env, array, 0, len, (jbyte *)buf);
}

static jbyteArray browse_new_bytes(JNIEnv *env, const void *buf, jsize len) {
    jbyteArray array = (*env)->NewByteArray(env, len);
    if (array != NULL) {
        (*env)->SetByteArrayRegion(env, array, 0, len, (const jbyte *)buf);
    }
    return array;
}
*/
import "C"

import (
	"unsafe"

	"github.com/flunderpero/cling-sync-clients/browse"
)

//export Java_com_clingsync_android_GoBrowse_Execute
func Java_com_clingsync_android_GoBrowse_Execute(
	env *C.JNIEnv,
	obj C.jobject,
	cmdStr C.jstring,
	paramsBytes C.jbyteArray,
) C.jbyteArray {
	cmdCStr := C.browse_get_string(env, cmdStr)
	command := C.GoString(cmdCStr)
	C.browse_release_string(env, cmdStr, cmdCStr)
	params := make([]byte, int(C.browse_array_length(env, paramsBytes)))
	if len(params) > 0 {
		C.browse_get_bytes(env, paramsBytes, C.jsize(len(params)), unsafe.Pointer(&params[0]))
	}

	// Never empty: every result is a JSON object.
	result := []byte(browse.Execute(command, string(params)))

	return C.browse_new_bytes(env, unsafe.Pointer(&result[0]), C.jsize(len(result)))
}
