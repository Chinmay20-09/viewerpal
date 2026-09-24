package com.example.viewerpal

import android.net.Uri
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * App-owned SAF bridge used by DocumentAccess (lib/core/services/document_access.dart).
 *
 * `readBytes` resolves a `content://` URI through the platform ContentResolver,
 * honoring both fresh picker grants and permissions persisted with
 * [android.content.ContentResolver.takePersistableUriPermission]. This lets the
 * app re-read the ORIGINAL document after restarts without any temp-path
 * assumptions; local paths and errors are reported cleanly instead of crashing.
 */
class MainActivity : FlutterActivity() {
    private val channelName = "viewerpal/document_access"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "readBytes" -> {
                        val uri = Uri.parse(call.argument<String>("uri"))
                        val bytes = readBytesFromUri(uri)
                        if (bytes != null) {
                            result.success(bytes)
                        } else {
                            result.error(
                                "unreadable",
                                "File is no longer accessible. Its access permission may have been revoked, or the file was moved or deleted.",
                                null
                            )
                        }
                    }
                    "tempDir" -> result.success(cacheDir.absolutePath)
                    "appFilesDir" -> result.success(filesDir.absolutePath)
                    else -> result.notImplemented()
                }
            }
    }

    /** Reads all bytes behind a SAF/content [uri]; null when unreadable. */
    private fun readBytesFromUri(uri: Uri): ByteArray? {
        return try {
            contentResolver.openInputStream(uri)?.use { input ->
                input.readBytes()
            }
        } catch (e: Exception) {
            // SecurityException (revoked grant), FileNotFoundException (moved/
            // deleted), IOException — all surface as "no longer accessible".
            null
        }
    }
}
