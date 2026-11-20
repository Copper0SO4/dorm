package org.dormos.dormos

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException

class MainActivity : FlutterActivity() {
    private data class DocumentSave(val source: File, val reply: MethodChannel.Result)

    private var pendingDocument: DocumentSave? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "org.dormos.dormos/documents")
            .setMethodCallHandler { call, result ->
                if (call.method != "save") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }

                val name = call.argument<String>("name")
                val path = call.argument<String>("path")
                val mimeType = call.argument<String>("mimeType") ?: "application/octet-stream"
                val source = try {
                    path?.let { File(it).canonicalFile }
                } catch (_: IOException) {
                    null
                }
                if (name == null || source == null || source.name != name ||
                    !source.path.startsWith(cacheDir.canonicalPath + File.separator) || !source.isFile
                ) {
                    result.error("invalid_document", "Invalid export file", null)
                } else if (pendingDocument != null) {
                    result.error("save_in_progress", "File picker already open", null)
                } else {
                    val create = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = mimeType
                        putExtra(Intent.EXTRA_TITLE, name)
                    }
                    pendingDocument = DocumentSave(source, result)
                    try {
                        @Suppress("DEPRECATION")
                        startActivityForResult(create, SAVE_DOCUMENT_REQUEST)
                    } catch (_: ActivityNotFoundException) {
                        pendingDocument = null
                        result.error("picker_unavailable", "File picker is unavailable", null)
                    }
                }
            }
    }

    @Deprecated("FlutterActivity dispatches the document picker result here.")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != SAVE_DOCUMENT_REQUEST) return
        val pending = pendingDocument ?: return
        pendingDocument = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            pending.reply.success(false)
            return
        }

        Thread {
            try {
                val stream = contentResolver.openOutputStream(uri) ?: throw IOException()
                stream.use { output -> pending.source.inputStream().use { it.copyTo(output) } }
                runOnUiThread { pending.reply.success(true) }
            } catch (_: IOException) {
                runOnUiThread { pending.reply.error("save_failed", "Cannot write document", null) }
            } catch (_: SecurityException) {
                runOnUiThread { pending.reply.error("save_failed", "Cannot access document", null) }
            }
        }.start()
    }

    private companion object {
        const val SAVE_DOCUMENT_REQUEST = 0x444f
    }
}
