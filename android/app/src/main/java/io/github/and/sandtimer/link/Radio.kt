package io.github.and.sandtimer.link

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.pm.PackageManager
import android.os.Handler
import android.os.ParcelUuid
import java.util.UUID

/**
 * The phone's side of the Bluetooth link: it looks for the service its key names, connects to the Mac offering it,
 * writes its messages to one characteristic and hears the Mac's as notifications on the other, each message cut
 * into pieces that fit (Crypto.frames). It keeps the connection slow and quiet, and when the Mac goes out of reach it
 * looks again after a while, waiting longer each time, rather than searching without a break.
 *
 * Bluetooth's callbacks arrive on their own threads; everything here is handed to the main one.
 */
@SuppressLint("MissingPermission")  // every call is behind [allowed]
class Radio(private val context: Context, private val engine: LinkEngine, private val main: Handler) : LinkTransport {
    private val adapter = context.getSystemService(BluetoothManager::class.java)?.adapter
    private var service: UUID? = null
    private var scanning = false
    private var gatt: BluetoothGatt? = null
    private var toMac: BluetoothGattCharacteristic? = null
    /** The Mac, once it is connected and listening. */
    private var peer: String? = null
    private var mtu = 23
    private val outbox = ArrayDeque<ByteArray>()
    private var writing = false
    private val inbox = Reassembler()
    private var attempts = 0
    private val retry = Runnable { look() }
    /** Called when the connection comes or goes, or Bluetooth stops being usable. */
    var onChange: () -> Unit = {}

    val allowed: Boolean
        get() = listOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
            .all { context.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }

    /** Why the phone can't reach the Mac, if it can't. */
    val problem: String?
        get() = when {
            adapter == null -> "This phone has no Bluetooth."
            !allowed -> "Sand Timer needs permission to find your Mac over Bluetooth."
            !adapter.isEnabled -> "Bluetooth is off."
            else -> null
        }

    override fun start(service: UUID) {
        this.service = service
        attempts = 0
        look()
    }

    override fun stop() {
        service = null
        main.removeCallbacks(retry)
        stopScan()
        drop()
    }

    override fun send(message: ByteArray, peer: String) {
        if (peer != this.peer) return
        outbox.addAll(Crypto.frames(message, minOf(mtu - 3, 512)))  // no attribute holds more than 512 bytes
        pump()
    }

    /** Looks for the Mac now: the app came to the front, or Bluetooth was turned on. */
    fun wake() {
        attempts = 0
        main.removeCallbacks(retry)
        look()
    }

    private fun look() {
        val service = service ?: return
        if (gatt != null || scanning) return
        val scanner = adapter?.takeIf { allowed && it.isEnabled }?.bluetoothLeScanner ?: return onChange()
        val filter = ScanFilter.Builder().setServiceUuid(ParcelUuid(service)).build()
        val settings = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_BALANCED).build()
        scanning = true
        runCatching { scanner.startScan(listOf(filter), settings, scan) }.onFailure { scanning = false }
    }

    private fun stopScan() {
        if (!scanning) return
        scanning = false
        runCatching { adapter?.bluetoothLeScanner?.stopScan(scan) }
    }

    private val scan = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            main.post { connect(result.device) }
        }

        override fun onScanFailed(errorCode: Int) {
            main.post {
                scanning = false
                again()
            }
        }
    }

    private fun connect(device: BluetoothDevice) {
        if (gatt != null || service == null) return
        stopScan()
        gatt = device.connectGatt(context, false, callback, BluetoothDevice.TRANSPORT_LE)
    }

    /** Lets go of the connection, telling the engine if the Mac had been listening. */
    private fun drop() {
        val was = peer
        peer = null
        toMac = null
        outbox.clear()
        writing = false
        inbox.reset()
        gatt?.let { runCatching { it.disconnect(); it.close() } }
        gatt = null
        if (was != null) engine.disconnected(was)
        onChange()
    }

    /** Tries again after a while: 2 s, then 5, 15, 30, and a minute from then on. */
    private fun again() {
        if (service == null) return
        val delay = listOf(2_000L, 5_000L, 15_000L, 30_000L, 60_000L)[minOf(attempts, 4)]
        attempts++
        main.removeCallbacks(retry)
        main.postDelayed(retry, delay)
    }

    private fun pump() {
        val gatt = gatt ?: return
        val toMac = toMac ?: return
        if (writing) return
        val frame = outbox.firstOrNull() ?: return
        writing = true
        // A write Android refuses outright leaves the message broken: start the connection over instead.
        val status = runCatching { gatt.writeCharacteristic(toMac, frame, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT) }
            .getOrElse { drop(); again(); return }
        if (status != BluetoothStatusCodes.SUCCESS) {
            writing = false
            main.postDelayed({ pump() }, 50)  // the stack is busy for a moment
        }
    }

    private val callback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) = main.post {
            if (g != gatt) return@post
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                g.requestMtu(517)
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                drop()
                again()
            }
        }.let {}

        override fun onMtuChanged(g: BluetoothGatt, mtu: Int, status: Int) = main.post {
            if (g != gatt) return@post
            this@Radio.mtu = if (status == BluetoothGatt.GATT_SUCCESS) mtu else 23
            g.discoverServices()
        }.let {}

        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) = main.post {
            if (g != gatt) return@post
            val offered = g.getService(service)
            val toPhone = offered?.getCharacteristic(Crypto.TO_PHONE)
            toMac = offered?.getCharacteristic(Crypto.TO_MAC)
            val cccd = toPhone?.getDescriptor(CCCD)
            if (toPhone == null || toMac == null || cccd == null) {
                drop()
                again()
                return@post
            }
            g.setCharacteristicNotification(toPhone, true)
            g.writeDescriptor(cccd, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)
        }.let {}

        override fun onDescriptorWrite(g: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) = main.post {
            if (g != gatt) return@post
            if (status != BluetoothGatt.GATT_SUCCESS) {
                drop()
                again()
                return@post
            }
            attempts = 0
            peer = g.device.address
            g.requestConnectionPriority(BluetoothGatt.CONNECTION_PRIORITY_LOW_POWER)  // a timer has little to say
            engine.connected(peer!!)
            onChange()
        }.let {}

        override fun onCharacteristicChanged(g: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray) {
            val copy = value.copyOf()
            main.post {
                val peer = peer ?: return@post
                if (g != gatt || characteristic.uuid != Crypto.TO_PHONE) return@post
                inbox.add(copy)?.let { engine.received(it, peer) }
            }
        }

        override fun onCharacteristicWrite(g: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) = main.post {
            if (g != gatt) return@post
            writing = false
            if (status == BluetoothGatt.GATT_SUCCESS) outbox.removeFirstOrNull()
            pump()
        }.let {}
    }

    companion object {
        private val CCCD: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    }
}
