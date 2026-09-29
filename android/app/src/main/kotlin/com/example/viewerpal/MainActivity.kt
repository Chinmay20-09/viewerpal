package com.example.viewerpal

import android.net.Uri
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/// Hosts the `viewerpal/document_access` method channel used by
/// [DocumentAccess] (Dart side) to:
///
///  - `readBytes`    : read the full byte content of an Android SAF
///                     `content://` URI through the platform ContentResolver
///                     (works with live picks and persisted grants restored
///                     after app restarts),
///  - `tempDir`      : provide the app cache directory for read-only working
///                     copies,
///  - `appFilesDir`  : provide the app files directory for persistent
///                     app-managed copies.
class MainActivity : FlutterActivity() {

    private companion object {
        const val CHANNEL_NAME = "viewerpal/document_access"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_NAME)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "readBytes" -> {
                            val uri = call.argument<String>("uri")
                            if (uri.isNullOrEmpty()) {
                                result.error(
                                    "invalid_args",
                                    "uri is required",
                                    null,
                                )
                            } else {
                                val bytes = readUriBytes(uri)
                                if (bytes == null) {
                                    result.error(
                                        "unreadable",
                                        "The file could not be read. Its access " +
                                            "permission may have been revoked, or " +
                                            "the file was moved or deleted.",
                                        null,
                                    )
                                } else {
                                    result.success(bytes)
                                }
                            }
                        }

                        "tempDir" -> result.success(cacheDir.absolutePath)

                        "appFilesDir" -> result.success(appFilesDirPath())

                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("error", e.message ?: e.javaClass.simpleName, null)
                }
            }
    }

    /// Reads the full byte content of a `content://` (or `file://`) URI via
    /// the ContentResolver. Returns null when the URI cannot be opened.
    private fun readUriBytes(uriString: String): ByteArray? {
        return try {
            val uri = Uri.parse(uriString)
            contentResolver.openInputStream(uri)?.use { stream ->
                stream.readBytes()
            }
        } catch (e: Exception) {
            null
        }
    }

    /// `files/saved_copies` inside the app's private storage, created on demand.
    private fun appFilesDirPath(): String {
        val dir = File(filesDir, "saved_copies")
        if (!dir.exists()) {
            dir.mkdirs()
        }
        return dir.absolutePath
    }
}
