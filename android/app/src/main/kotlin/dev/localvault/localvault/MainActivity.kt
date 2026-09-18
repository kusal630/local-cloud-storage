package dev.localvault.localvault

import android.os.Environment
import android.os.StatFs
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        const val DISK_CHANNEL = "dev.localvault.localvault/disk"
        const val HOST_CHANNEL = "dev.localvault.localvault/host"
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
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            HOST_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "startHost" -> {
                    try {
                        val label = call.argument<String>("label")
                            ?: "LocalVault"
                        val port = call.argument<Int>("port") ?: 8484
                        HostService.start(this, label, port)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("HOST_START_FAILED", e.message, null)
                    }
                }
                "stopHost" -> {
                    try {
                        HostService.stop(this)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("HOST_STOP_FAILED", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}
