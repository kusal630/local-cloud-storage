package dev.localvault.localvault

import android.os.Environment
import android.os.StatFs
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        const val DISK_CHANNEL = "dev.localvault.localvault/disk"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            DISK_CHANNEL,
        ).setMethodCallHandler { call, result ->
            if (call.method == "getSpace") {
                try {
                    val path = Environment.getDataDirectory().path
                    val stat = StatFs(path)
                    val blockSize = stat.blockSizeLong
                    result.success(
                        mapOf(
                            "total" to stat.blockCountLong * blockSize,
                            "free" to stat.availableBlocksLong * blockSize,
                        ),
                    )
                } catch (e: Exception) {
                    result.error("UNAVAILABLE", e.message, null)
                }
            } else {
                result.notImplemented()
            }
        }
    }
}
