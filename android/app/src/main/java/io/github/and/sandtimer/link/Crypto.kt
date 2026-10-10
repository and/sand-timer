package io.github.and.sandtimer.link

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * What linked devices agree on, as the Mac has it in Sources/LinkFormat.swift: how each message is sealed, the
 * Bluetooth service the key names, and how a message is cut into pieces small enough for Bluetooth.
 */
object Crypto {
    /** AES-GCM, as nonce (12 bytes) + ciphertext + tag (16 bytes): CryptoKit's sealed box "combined". */
    fun seal(data: ByteArray, key: ByteArray): ByteArray {
        val nonce = ByteArray(12).also { SecureRandom().nextBytes(it) }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
        return nonce + cipher.doFinal(data)
    }

    fun open(data: ByteArray, key: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, data, 0, 12))
        return cipher.doFinal(data, 12, data.size - 12)
    }

    fun keyFromBase64(text: String): ByteArray = Base64.getDecoder().decode(text)
    fun keyToBase64(key: ByteArray): String = Base64.getEncoder().encodeToString(key)

    /** The Mac's Bluetooth service, its UUID drawn from the key, so a phone never mistakes another Mac for its own. */
    fun serviceUuid(key: ByteArray): UUID {
        val b = MessageDigest.getInstance("SHA-256").digest("sandtimer-service".toByteArray() + key).copyOf(16)
        b[6] = (b[6].toInt() and 0x0f or 0x40).toByte()
        b[8] = (b[8].toInt() and 0x3f or 0x80).toByte()
        val buffer = ByteBuffer.wrap(b)
        return UUID(buffer.long, buffer.long)
    }

    /** The phone writes to the first characteristic, and hears from the Mac on the second. */
    val TO_MAC: UUID = UUID.fromString("6C2ED600-0001-4D61-9C00-53616E645469")
    val TO_PHONE: UUID = UUID.fromString("6C2ED600-0002-4D61-9C00-53616E645469")

    /** A short digest of a month of the record that doesn't depend on the order its keys were written in. */
    fun digest(element: JsonElement): String =
        MessageDigest.getInstance("SHA-256").digest(canonical(element).toByteArray()).copyOf(8).joinToString("") { "%02x".format(it) }

    private fun canonical(element: JsonElement): String = when (element) {
        is JsonObject -> element.entries.sortedBy { it.key }.joinToString(",", "{", "}") { "\"${it.key}\":${canonical(it.value)}" }
        is JsonArray -> element.joinToString(",", "[", "]") { canonical(it) }
        else -> element.toString()
    }

    /** A sealed message in pieces of at most [size] bytes: a byte saying whether more follow (1) or not (0), then the rest. */
    fun frames(message: ByteArray, size: Int): List<ByteArray> {
        val chunk = maxOf(1, size - 1)
        val out = mutableListOf<ByteArray>()
        var start = 0
        do {
            val end = minOf(message.size, start + chunk)
            out += byteArrayOf(if (end < message.size) 1 else 0) + message.copyOfRange(start, end)
            start = end
        } while (start < message.size)
        return out
    }
}

/** Puts the pieces of a message back together. */
class Reassembler {
    private val buffer = ByteArrayOutputStream()

    /** The whole message once its last piece has come, else null. */
    fun add(frame: ByteArray): ByteArray? {
        if (frame.isEmpty()) return null
        buffer.write(frame, 1, frame.size - 1)
        if (buffer.size() > 2 shl 20) { buffer.reset(); return null }
        if (frame[0].toInt() != 0) return null
        return buffer.toByteArray().also { buffer.reset() }
    }

    fun reset() = buffer.reset()
}

/** What the Mac's QR code says: "sandtimer-link:2:<key, base64url>". */
object LinkCode {
    const val PREFIX = "sandtimer-link:2:"

    fun parse(text: String): ByteArray? {
        val t = text.trim()
        if (!t.startsWith(PREFIX)) return null
        val key = runCatching { Base64.getUrlDecoder().decode(t.removePrefix(PREFIX)) }.getOrNull() ?: return null
        return key.takeIf { it.size == 32 }
    }
}
