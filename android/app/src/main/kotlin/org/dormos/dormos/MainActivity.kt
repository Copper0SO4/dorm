package org.dormos.dormos

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.IOException

class MainActivity : FlutterActivity() {
    private data class InviteSave(val bytes: ByteArray, val reply: MethodChannel.Result)

    private var pendingInvite: InviteSave? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "org.dormos.dormos/invites")
            .setMethodCallHandler { call, result ->
                if (call.method != "save") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }

                val name = call.argument<String>("name")
                val bytes = call.argument<ByteArray>("bytes")
                if (name == null || !name.endsWith(".dorm") || bytes == null || bytes.size > 65536) {
                    result.error("invalid_invite", "Invalid invite file", null)
                } else if (pendingInvite != null) {
                    result.error("save_in_progress", "File picker already open", null)
                } else {
                    val create = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "application/octet-stream"
                        putExtra(Intent.EXTRA_TITLE, name)
                    }
                    pendingInvite = InviteSave(bytes, result)
                    try {
                        @Suppress("DEPRECATION")
                        startActivityForResult(create, SAVE_INVITE_REQUEST)
                    } catch (_: ActivityNotFoundException) {
                        pendingInvite = null
                        result.error("picker_unavailable", "File picker is unavailable", null)
                    }
                }
            }
    }

    @Deprecated("FlutterActivity dispatches the document picker result here.")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != SAVE_INVITE_REQUEST) return
        val pending = pendingInvite ?: return
        pendingInvite = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            pending.reply.success(false)
            return
        }

        Thread {
            try {
                val stream = contentResolver.openOutputStream(uri) ?: throw IOException()
                stream.use { it.write(pending.bytes) }
                runOnUiThread { pending.reply.success(true) }
            } catch (_: IOException) {
                runOnUiThread { pending.reply.error("save_failed", "Cannot write invite", null) }
            } catch (_: SecurityException) {
                runOnUiThread { pending.reply.error("save_failed", "Cannot access document", null) }
            }
        }.start()
    }

    private companion object {
        const val SAVE_INVITE_REQUEST = 0x444f
    }
}
