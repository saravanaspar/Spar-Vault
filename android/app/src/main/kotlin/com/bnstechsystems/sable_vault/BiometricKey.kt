package com.bnstechsystems.sable_vault

import android.Manifest
import android.app.Activity
import android.app.KeyguardManager
import android.content.pm.PackageManager
import android.hardware.biometrics.BiometricManager
import android.hardware.biometrics.BiometricPrompt
import android.os.Build
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyInfo
import android.security.keystore.KeyProperties
import android.util.Base64
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec

// Separate opt-in bindings: strong biometrics, or strong biometrics OR screen
// credential. Each prompt authorizes the actual hardware cipher on every use.
class BiometricKey(private val activity: Activity, private val deviceLock: Boolean = false) {
    private val prefix = if (deviceLock) "spar-vault-device-v1" else "spar-vault-biometric-v1"
    private val prefs = activity.getSharedPreferences(if (deviceLock) "spar-device-v1" else "spar-biometric-v1", Activity.MODE_PRIVATE)
    private val authenticators get() = BiometricManager.Authenticators.BIOMETRIC_STRONG or
        if (deviceLock) BiometricManager.Authenticators.DEVICE_CREDENTIAL else 0
    private val keyAuthenticators get() = KeyProperties.AUTH_BIOMETRIC_STRONG or
        if (deviceLock) KeyProperties.AUTH_DEVICE_CREDENTIAL else 0
    private val store get() = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
    private fun validId(id: String) = Regex("^[a-f0-9]{32}$").matches(id)
    private fun validAlias(alias: String) = alias == prefix || Regex("^$prefix-[a-f0-9-]{36}$").matches(alias)
    private fun storedAlias() = prefs.getString("alias", prefix) ?: prefix // Legacy binding stays readable.
    private class Operation(val result: MethodChannel.Result, val bytes: ByteArray,
        val alias: String, val creating: Boolean, val cipher: Cipher) {
        val signal = CancellationSignal()
    }
    private var pending: Operation? = null
    private val handler = Handler(Looper.getMainLooper())
    private var timeout: Runnable? = null
    val prompting get() = pending != null

    fun status(): String {
        if (Build.VERSION.SDK_INT < 30) return "unsupported"
        if (activity.checkSelfPermission(Manifest.permission.USE_BIOMETRIC) != PackageManager.PERMISSION_GRANTED) return "permission"
        if (deviceLock && !activity.getSystemService(KeyguardManager::class.java).isDeviceSecure) return "not_enrolled"
        return when (activity.getSystemService(BiometricManager::class.java).canAuthenticate(authenticators)) {
            BiometricManager.BIOMETRIC_SUCCESS -> "ready"
            BiometricManager.BIOMETRIC_ERROR_NONE_ENROLLED -> "not_enrolled"
            BiometricManager.BIOMETRIC_ERROR_NO_HARDWARE -> "no_hardware"
            BiometricManager.BIOMETRIC_ERROR_HW_UNAVAILABLE -> "temporarily_unavailable"
            BiometricManager.BIOMETRIC_ERROR_SECURITY_UPDATE_REQUIRED -> "security_update"
            21 -> "not_enabled" // Android 16: biometrics disabled for apps.
            else -> "temporarily_unavailable"
        }
    }
    fun available() = status() == "ready"
    fun enabled(id: String): Boolean {
        if (Build.VERSION.SDK_INT < 30 || !validId(id) || prefs.getString("vaultId", null) != id) return false
        val alias = storedAlias()
        return validAlias(alias) && store.containsAlias(alias)
    }
    fun clear() {
        dispose()
        val alias = storedAlias()
        if (!prefs.edit().clear().commit()) throw IllegalStateException("Binding removal failed")
        if (validAlias(alias)) deleteKey(alias)
        store.aliases().toList().filter { validAlias(it) }.forEach { deleteKey(it) }
    }
    private fun deleteKey(alias: String) { try { if (store.containsAlias(alias)) store.deleteEntry(alias) } catch (_: Exception) {} }
    private fun hardware(key: SecretKey): Boolean {
        val info = SecretKeyFactory.getInstance(key.algorithm, "AndroidKeyStore").getKeySpec(key, KeyInfo::class.java) as KeyInfo
        val hardware = if (Build.VERSION.SDK_INT >= 31)
            info.securityLevel == KeyProperties.SECURITY_LEVEL_TRUSTED_ENVIRONMENT || info.securityLevel == KeyProperties.SECURITY_LEVEL_STRONGBOX
            else info.isInsideSecureHardware
        return hardware && info.isUserAuthenticationRequired && info.isUserAuthenticationRequirementEnforcedBySecureHardware &&
            info.userAuthenticationValidityDurationSeconds == 0 && info.userAuthenticationType == keyAuthenticators
    }
    private fun generate(alias: String): SecretKey {
        fun make(strongBox: Boolean): SecretKey {
            val builder = KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256).setUserAuthenticationRequired(true)
                .setUserAuthenticationParameters(0, keyAuthenticators)
                .setInvalidatedByBiometricEnrollment(!deviceLock)
            if (strongBox) builder.setIsStrongBoxBacked(true)
            return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply { init(builder.build()) }.generateKey()
        }
        val key = try { make(true) } catch (_: Exception) { deleteKey(alias); make(false) }
        if (!hardware(key)) { deleteKey(alias); throw SecurityException("Hardware authentication required") }
        return key
    }
    private fun aad(id: String) = "SparVault/${if (deviceLock) "device-lock" else "biometric"}/v1|$id".toByteArray(Charsets.UTF_8)
    private fun preflight(result: MethodChannel.Result): Boolean {
        if (prompting) { result.error("busy", "An Android authentication prompt is already open.", null); return false }
        val state = status()
        if (state == "ready") return true
        result.error(state, when (state) {
            "not_enrolled" -> "Set up a phone screen lock or strong fingerprint in Android settings, then try again."
            "permission", "not_enabled" -> "Android blocked authentication for apps. Review Android app/security settings."
            "no_hardware" -> "A strong biometric sensor is unavailable. Try Phone screen lock or your vault password/key."
            "security_update" -> "Android requires a security update before this biometric sensor can be used."
            "unsupported" -> "Hardware-bound quick unlock requires Android 11 or newer."
            else -> "Android authentication is temporarily unavailable. Retry or use your vault password/key."
        }, null)
        return false
    }
    fun enable(id: String, bytes: ByteArray, result: MethodChannel.Result) {
        var alias: String? = null
        try {
            if (!validId(id) || bytes.size != 32) { result.error("invalid", "Invalid device-binding request.", null); return }
            if (!preflight(result)) return
            // Preserve a working old binding until the new cipher succeeds.
            alias = "$prefix-${UUID.randomUUID()}"
            val key = generate(alias)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, key); cipher.updateAAD(aad(id))
            val operation = Operation(result, bytes.copyOf(), alias, true, cipher)
            pending = operation
            prompt(operation) { authorized ->
                val wrapped = authorized.doFinal(operation.bytes)
                try {
                    if (authorized.iv.size != 12 || wrapped.size != 48) throw SecurityException()
                    val oldAlias = storedAlias()
                    if (!prefs.edit().putString("alias", operation.alias).putString("vaultId", id)
                            .putString("nonce", Base64.encodeToString(authorized.iv, Base64.NO_WRAP))
                            .putString("wrapped", Base64.encodeToString(wrapped, Base64.NO_WRAP)).commit()) throw IllegalStateException()
                    if (validAlias(oldAlias) && oldAlias != operation.alias) deleteKey(oldAlias)
                    finish(operation, null, null)
                } finally { wrapped.fill(0) }
            }
        } catch (_: Exception) {
            val operation = pending
            if (operation != null) finish(operation, null, "hardware", "Android could not authorize hardware key wrapping. Use your vault password/key.")
            else { alias?.let { deleteKey(it) }; result.error("hardware", "Hardware-backed authentication is unavailable on this device. Use your vault password/key.", null) }
        } finally { bytes.fill(0) }
    }
    fun unlock(id: String, result: MethodChannel.Result) {
        if (!preflight(result)) return
        var wrapped: ByteArray? = null
        try {
            if (!enabled(id)) { result.error("invalidated", "Device unlock is not enabled for this vault. Unlock with your password/key and enable it again.", null); return }
            val alias = storedAlias()
            val key = store.getKey(alias, null) as SecretKey
            if (!hardware(key)) throw SecurityException()
            val nonce = Base64.decode(prefs.getString("nonce", ""), Base64.NO_WRAP)
            wrapped = Base64.decode(prefs.getString("wrapped", ""), Base64.NO_WRAP)
            if (nonce.size != 12 || wrapped.size != 48) throw SecurityException()
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, nonce)); cipher.updateAAD(aad(id))
            val operation = Operation(result, wrapped, alias, false, cipher)
            pending = operation; wrapped = null
            prompt(operation) { authorized ->
                val root = authorized.doFinal(operation.bytes)
                try { if (root.size != 32) throw SecurityException(); finish(operation, root, null) }
                finally { root.fill(0) }
            }
        } catch (_: Exception) {
            val operation = pending
            if (operation != null) finish(operation, null, "invalidated", "Device binding is unavailable. Use your vault password/key and enable it again.")
            else result.error("invalidated", "Device binding changed or is unavailable. Use your vault password/key and enable it again.", null)
        } finally { wrapped?.fill(0) }
    }
    private fun prompt(operation: Operation, action: (Cipher) -> Unit) {
        timeout = Runnable {
            if (pending === operation) {
                finish(operation, null, "timeout", "Android authentication timed out. Please retry.")
                operation.signal.cancel()
            }
        }.also { handler.postDelayed(it, 90000) }
        val builder = BiometricPrompt.Builder(activity).setTitle("Unlock Spar Vault")
            .setSubtitle(if (deviceLock) "Fingerprint or phone PIN, pattern or password" else "Authorize with a strong fingerprint or face scan")
            .setAllowedAuthenticators(authenticators)
        // Android forbids a negative button when DEVICE_CREDENTIAL is enabled.
        if (!deviceLock) builder.setNegativeButton("Cancel", activity.mainExecutor) { _, _ -> cancel(operation) }
        builder.build().authenticate(BiometricPrompt.CryptoObject(operation.cipher), operation.signal,
            activity.mainExecutor, object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                    if (pending !== operation) return
                    try {
                        val cipher = result.cryptoObject?.cipher ?: throw SecurityException()
                        if (cipher !== operation.cipher) throw SecurityException()
                        action(cipher)
                    } catch (_: Exception) { finish(operation, null, "failed", "Android authentication did not complete the protected cipher operation. Use your vault password/key.") }
                }
                override fun onAuthenticationError(code: Int, message: CharSequence) {
                    val error = when (code) { 7, 9 -> "lockout"; 11, 14 -> "not_enrolled"; 15 -> "security_update"; 21 -> "not_enabled"; 1, 12 -> "temporarily_unavailable"; 3 -> "timeout"; 5, 10, 13 -> "cancelled"; else -> "failed" }
                    val text = when (error) {
                        "lockout" -> "Android locked the biometric sensor. Unlock your phone with its PIN or wait, then retry."
                        "not_enrolled" -> "Set up your fingerprint or phone screen lock in Android settings."
                        "not_enabled" -> "Allow biometrics for apps in Android settings."
                        "security_update" -> "Android requires a security update for this sensor."
                        "cancelled" -> "Android authentication was cancelled. You can retry or use your vault password/key."
                        "timeout" -> "Android authentication timed out. Please retry."
                        else -> "Android authentication is unavailable. Retry or use your vault password/key."
                    }
                    finish(operation, null, error, text, code)
                }
            })
    }
    private fun finish(operation: Operation, value: ByteArray?, error: String?, message: String = "Android authentication was cancelled.", androidCode: Int? = null) {
        if (pending !== operation) return // Stale callbacks cannot finish a newer prompt.
        pending = null
        timeout?.let { handler.removeCallbacks(it) }; timeout = null
        operation.bytes.fill(0)
        if (error != null && operation.creating) deleteKey(operation.alias)
        if (error == null) operation.result.success(value)
        else operation.result.error(error, message, androidCode?.let { mapOf("androidCode" to it) })
    }
    private fun cancel(operation: Operation) {
        finish(operation, null, "cancelled")
        operation.signal.cancel()
    }
    fun dispose() { pending?.let { cancel(it) } }
}
