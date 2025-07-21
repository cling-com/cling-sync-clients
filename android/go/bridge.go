// Bridge between Go and Android/JVM.

package main

/*
#include "../tools/android-sdk/ndk/jni-headers/jni.h"
#include <stdlib.h>

static jstring new_string(JNIEnv *env, const char *str) {
    return (*env)->NewStringUTF(env, str);
}

static const char* get_string(JNIEnv *env, jstring str) {
    return (*env)->GetStringUTFChars(env, str, NULL);
}

static void release_string(JNIEnv *env, jstring str, const char *chars) {
    (*env)->ReleaseStringUTFChars(env, str, chars);
}
*/
import "C"

import (
	"unsafe"

	"github.com/flunderpero/cling-sync-clients/bridge"
)

//export Java_com_clingsync_android_GoBridge_Execute
func Java_com_clingsync_android_GoBridge_Execute(
	env *C.JNIEnv,
	obj C.jobject,
	cmdStr C.jstring,
	paramsStr C.jstring,
) C.jstring {
	// Convert jstrings to Go strings.
	cmdCStr := C.get_string(env, cmdStr)
	command := C.GoString(cmdCStr)
	C.release_string(env, cmdStr, cmdCStr)
	paramsCStr := C.get_string(env, paramsStr)
	params := C.GoString(paramsCStr)
	C.release_string(env, paramsStr, paramsCStr)

	// Execute command and get result.
	result := bridge.Execute(command, params)

	// Convert result back to jstring.
	resultCStr := C.CString(result)
	defer C.free(unsafe.Pointer(resultCStr))
	return C.new_string(env, resultCStr)
}

func main() {}
