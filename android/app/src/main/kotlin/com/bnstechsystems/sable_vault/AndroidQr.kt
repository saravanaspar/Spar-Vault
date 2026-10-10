package com.bnstechsystems.sable_vault

import android.app.Activity
import android.content.Intent
import android.graphics.BitmapFactory
import com.google.zxing.BinaryBitmap
import com.google.zxing.RGBLuminanceSource
import com.google.zxing.common.HybridBinarizer
import com.google.zxing.multi.qrcode.QRCodeMultiReader
import com.google.zxing.integration.android.IntentIntegrator
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

class AndroidQr(private val activity: Activity) {
    private var pending: MethodChannel.Result? = null
    private val worker = Executors.newSingleThreadExecutor()
    private var generation = 0
    fun scan(image: Boolean, result: MethodChannel.Result) {
        if (pending != null) { result.error("busy", "A QR scanner is already open.", null); return }
        pending = result; generation++
        try {
            if (image) activity.startActivityForResult(Intent(Intent.ACTION_GET_CONTENT).apply {
                type = "image/*"; addCategory(Intent.CATEGORY_OPENABLE)
            }, 4106)
            else IntentIntegrator(activity).setDesiredBarcodeFormats(IntentIntegrator.QR_CODE)
                .setPrompt("Scan an authenticator QR code").setBeepEnabled(false)
                .setBarcodeImageEnabled(false).setOrientationLocked(false).setTimeout(120000L).initiateScan()
        } catch (_: Exception) {
            pending = null; result.error("scanner", "Could not open the QR scanner. Check camera permission or choose a QR image.", null)
        }
    }
    fun onResult(code: Int, resultCode: Int, data: Intent?): Boolean {
        if (code != 4106 && code != IntentIntegrator.REQUEST_CODE) return false
        val result = pending ?: return true
        if (resultCode != Activity.RESULT_OK) { pending = null; result.success(null); return true }
        if (code == IntentIntegrator.REQUEST_CODE) {
            val value = IntentIntegrator.parseActivityResult(code, resultCode, data)?.contents
            pending = null
            if (value != null && value.length <= 65536) result.success(listOf(value))
            else result.error("qr", "No supported authenticator QR code was found.", null)
            return true
        }
        val uri = data?.data
        if (uri == null || uri.scheme != "content") { pending = null; result.error("image", "Choose a QR image from your phone.", null); return true }
        val epoch = generation
        worker.execute {
            var encoded: ByteArray? = null
            try {
                encoded = activity.contentResolver.openInputStream(uri)?.use { input ->
                    val output = ByteArrayOutputStream(); val chunk = ByteArray(8192)
                    try {
                        while (true) {
                            val length = input.read(chunk); if (length < 0) break
                            if (output.size() + length > 8 * 1024 * 1024) throw IllegalArgumentException()
                            output.write(chunk, 0, length)
                        }
                        output.toByteArray()
                    } finally { chunk.fill(0) }
                } ?: throw IllegalArgumentException()
                val bytes = encoded
                val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
                if (bounds.outWidth <= 0 || bounds.outHeight <= 0) throw IllegalArgumentException()
                var sample = 1
                while ((bounds.outWidth.toLong() / sample) * (bounds.outHeight / sample) > 4_000_000L) sample *= 2
                val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size, BitmapFactory.Options().apply { inSampleSize = sample }) ?: throw IllegalArgumentException()
                val pixels = IntArray(bitmap.width * bitmap.height)
                val values = try {
                    bitmap.getPixels(pixels, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
                    QRCodeMultiReader().decodeMultiple(BinaryBitmap(HybridBinarizer(RGBLuminanceSource(bitmap.width, bitmap.height, pixels))))
                        .map { it.text }.filter { it.length <= 65536 }.distinct().take(20)
                } finally { pixels.fill(0); bitmap.recycle() }
                activity.runOnUiThread {
                    if (generation == epoch && pending === result) { pending = null; result.success(values) }
                }
            } catch (_: Exception) {
                activity.runOnUiThread {
                    if (generation == epoch && pending === result) { pending = null; result.error("qr", "No readable QR code was found. Choose a clear, uncropped QR image.", null) }
                }
            } finally { encoded?.fill(0) }
        }
        return true
    }
    fun dispose() { generation++; pending?.success(null); pending = null; worker.shutdownNow() }
}
