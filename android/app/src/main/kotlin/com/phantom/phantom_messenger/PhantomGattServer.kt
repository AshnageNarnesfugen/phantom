package com.phantom.phantom_messenger

import android.annotation.SuppressLint
import android.bluetooth.*
import android.bluetooth.le.*
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import io.flutter.plugin.common.MethodChannel
import java.util.UUID

/**
 * Thrown by [PhantomGattServer.start] when the server cannot be started.
 * [code] maps to the PlatformException code surfaced on the Dart side:
 *   BT_DISABLED        — adapter is off; user needs to enable Bluetooth
 *   PERMISSION_DENIED  — BLUETOOTH_CONNECT / ADVERTISE not granted
 *   GATT_SERVER_FAILED — system rejected openGattServer() (rare hardware issue)
 */
class GattStartException(val code: String, override val message: String) : Exception(message)

private val PHANTOM_SVC_UUID  = UUID.fromString("50480001-4d45-5348-424c-450000000001")
private val PHANTOM_CHAR_UUID = UUID.fromString("50480001-4d45-5348-424c-450000000002")
private val CCCD_UUID         = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

/**
 * PhantomGattServer — Android BLE peripheral for the Phantom mesh.
 *
 * Responsibilities:
 *   1. GATT server: expose Phantom service + writable characteristic so
 *      remote centrals (other Phantom phones) can write mesh packets to us.
 *   2. BLE advertiser: broadcast our presence with the Phantom service UUID
 *      and manufacturer data (nodeHint + capabilities) so the Flutter-side
 *      BLE scan (withServices filter) can discover us.
 *
 * Data flow (incoming):
 *   Remote phone writes to our characteristic
 *     → onCharacteristicWriteRequest
 *       → channel.invokeMethod("onWrite", bytes)
 *         → Dart GattServerChannel.received stream
 *           → BluetoothMeshTransport._receivePacket()
 *
 * Data flow (outgoing push):
 *   BluetoothMeshTransport calls notifyAll(data)
 *     → notifyCharacteristicChanged for each connected central
 *       → remote phone's characteristic.onValueReceived stream
 *         → their _receivePacket()
 *
 * Threading: GATT callbacks arrive on a binder pool thread. All Flutter channel
 * calls and mutable state (connectedDevices, phantomChar) are dispatched to the
 * main thread via mainHandler to avoid races.
 */
@SuppressLint("MissingPermission")
class PhantomGattServer(
    private val context: Context,
    private val channel: MethodChannel,
) {
    private val btManager = context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
    private val btAdapter get() = btManager.adapter

    // All state is read/written only on the main thread (see threading note above).
    private val mainHandler = Handler(Looper.getMainLooper())
    private var gattServer: BluetoothGattServer? = null
    private var phantomChar: BluetoothGattCharacteristic? = null
    private val connectedDevices = mutableSetOf<BluetoothDevice>()
    private var advertiseCallback: AdvertiseCallback? = null

    // ── Start ─────────────────────────────────────────────────────────────────

    /**
     * Start the GATT server and begin advertising.
     *
     * @param msdPayload 8-byte MeshAdvertisement payload:
     *   [0xFF][0xFF][0x50][hint0][hint1][hint2][hint3][caps]
     * @throws GattStartException if BT is off, permissions are missing, or the GATT server fails.
     */
    fun start(msdPayload: ByteArray) {
        if (!btAdapter.isEnabled) {
            throw GattStartException("BT_DISABLED", "Bluetooth está apagado")
        }
        startGattServer()
        startAdvertising(msdPayload)
    }

    private fun startGattServer() {
        if (gattServer != null) return

        val char = BluetoothGattCharacteristic(
            PHANTOM_CHAR_UUID,
            BluetoothGattCharacteristic.PROPERTY_WRITE or
                    BluetoothGattCharacteristic.PROPERTY_NOTIFY,
            BluetoothGattCharacteristic.PERMISSION_WRITE,
        ).apply {
            // CCCD descriptor — required so connected centrals can enable notifications
            addDescriptor(
                BluetoothGattDescriptor(
                    CCCD_UUID,
                    BluetoothGattDescriptor.PERMISSION_READ or
                            BluetoothGattDescriptor.PERMISSION_WRITE,
                )
            )
        }

        phantomChar = char

        val service = BluetoothGattService(
            PHANTOM_SVC_UUID,
            BluetoothGattService.SERVICE_TYPE_PRIMARY,
        ).also { it.addCharacteristic(char) }

        gattServer = btManager.openGattServer(context, gattCallback)
            ?.also { it.addService(service) }
            ?: throw GattStartException("GATT_SERVER_FAILED", "No se pudo abrir el GATT server")
    }

    private fun startAdvertising(msdPayload: ByteArray) {
        val advertiser = btAdapter.bluetoothLeAdvertiser ?: return

        // msdPayload = [0xFF, 0xFF, 0x50, h0, h1, h2, h3, caps]
        // Android addManufacturerData(companyId=0xFFFF, data=[0x50, h0, h1, h2, h3, caps])
        val companyId = 0xFFFF
        val advBytes  = if (msdPayload.size >= 8) msdPayload.drop(2).toByteArray()
                        else byteArrayOf(0x50, 0, 0, 0, 0, 0)

        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setConnectable(true)
            .setTimeout(0) // advertise indefinitely
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM)
            .build()

        val data = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .addServiceUuid(ParcelUuid(PHANTOM_SVC_UUID))
            .addManufacturerData(companyId, advBytes)
            .build()

        val cb = object : AdvertiseCallback() {
            override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {}
            override fun onStartFailure(errorCode: Int) {
                when (errorCode) {
                    // Transient failures — retry after a short delay
                    ADVERTISE_FAILED_INTERNAL_ERROR,
                    ADVERTISE_FAILED_TOO_MANY_ADVERTISERS -> {
                        mainHandler.postDelayed({
                            if (advertiseCallback != null) {
                                btAdapter.bluetoothLeAdvertiser
                                    ?.startAdvertising(settings, data, this)
                            }
                        }, 5_000)
                    }
                    // Permanent failure — notify Dart so the UI can inform the user
                    else -> mainHandler.post {
                        channel.invokeMethod("onAdvertiseFailed", errorCode)
                    }
                }
            }
        }
        advertiseCallback = cb
        advertiser.startAdvertising(settings, data, cb)
    }

    // ── Stop ──────────────────────────────────────────────────────────────────

    fun stop() {
        val cb = advertiseCallback
        if (cb != null) {
            btAdapter.bluetoothLeAdvertiser?.stopAdvertising(cb)
            advertiseCallback = null
        }
        gattServer?.close()
        gattServer = null
        phantomChar = null
        connectedDevices.clear()
    }

    // ── Notify all connected centrals ─────────────────────────────────────────

    /**
     * Push [data] to every connected central via GATT notification.
     * Returns the number of centrals that were successfully notified.
     *
     * Must be called from the main thread (MethodCallHandler guarantee).
     *
     * On API 33+: uses the new per-call data parameter to avoid the shared
     * characteristic.value buffer that causes corruption under concurrent calls.
     * On older APIs: characteristic.value is set once per device iteration;
     * since this runs on the main thread it is never concurrent.
     */
    fun notifyAll(data: ByteArray): Int {
        val server = gattServer ?: return 0
        val char = phantomChar ?: return 0

        var delivered = 0
        for (device in connectedDevices.toList()) {
            val ok = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                @Suppress("NewApi")
                server.notifyCharacteristicChanged(device, char, false, data) ==
                    BluetoothStatusCodes.SUCCESS
            } else {
                @Suppress("DEPRECATION")
                char.value = data
                @Suppress("DEPRECATION")
                server.notifyCharacteristicChanged(device, char, false)
            }
            if (ok) delivered++
        }
        return delivered
    }

    // ── GATT server callbacks ─────────────────────────────────────────────────

    private val gattCallback = object : BluetoothGattServerCallback() {

        override fun onConnectionStateChange(
            device: BluetoothDevice,
            status: Int,
            newState: Int,
        ) {
            // Dispatch to main thread so connectedDevices is only touched there.
            mainHandler.post {
                if (newState == BluetoothProfile.STATE_CONNECTED) {
                    connectedDevices.add(device)
                    channel.invokeMethod("onClientConnected", device.address)
                } else {
                    connectedDevices.remove(device)
                    channel.invokeMethod("onClientDisconnected", device.address)
                }
            }
        }

        override fun onMtuChanged(device: BluetoothDevice, mtu: Int) {
            // Notify Dart so the transport layer can warn about low-MTU peers.
            mainHandler.post { channel.invokeMethod("onMtuChanged", mtu) }
        }

        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            characteristic: BluetoothGattCharacteristic,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray,
        ) {
            // sendResponse must be called from the callback thread
            if (responseNeeded) {
                gattServer?.sendResponse(
                    device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null,
                )
            }
            // Copy before posting — Android may reuse the buffer after this returns
            val copy = value.copyOf()
            // Send ByteArray directly; StandardMethodCodec maps it to Uint8List on Dart side
            mainHandler.post { channel.invokeMethod("onWrite", copy) }
        }

        override fun onDescriptorWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            descriptor: BluetoothGattDescriptor,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray,
        ) {
            // Acknowledge CCCD writes so the central can enable notifications
            if (responseNeeded) {
                gattServer?.sendResponse(
                    device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null,
                )
            }
        }
    }
}
