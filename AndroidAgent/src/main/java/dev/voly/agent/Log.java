package dev.voly.agent;

/** Logging under one tag, so `adb logcat -s VolyAgent` shows everything. */
final class Log {
    private static final String TAG = "VolyAgent";

    private Log() {}

    static void i(String message) {
        android.util.Log.i(TAG, message);
    }

    static void w(String message) {
        android.util.Log.w(TAG, message);
    }

    static void e(String message, Throwable error) {
        android.util.Log.e(TAG, message, error);
    }
}
