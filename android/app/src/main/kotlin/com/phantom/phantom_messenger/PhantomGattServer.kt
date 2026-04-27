package com.phantom.phantom_messenger

import android.annotation.SuppressLint
import android.bluetooth.*
import android.bluetooth.le.*
import android.content.Context
import android.os.ParcelUuid
import io.flutter.plugin.common.MethodChannel
import java.util.UUID

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
 */
@SuppressLint("MissingPermission")
class PhantomGattServer(
    private val context: Context,
    private val channel: MethodChannel,
) {
    private val btManager = context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
    private val btAdapter get() = btManager.adapter

    private var gattServer: BluetoothGattServer? = null
    private val connectedDevices = mutableSetOf<BluetoothDevice>()
    private var advertiseCallback: AdvertiseCallback? = null

    // ── Start ─────────────────────────────────────────────────────────────────

    /**
     * Start the GATT server and begin advertising.
     *
     * @param msdPayload 8-byte MeshAdvertisement payload:
     *   [0xFF][0xFF][0x50][hint0][hint1][hint2][hint3][caps]
     *   (same format as MeshAdvertisement.toAdvPayload())
     */
    fun start(msdPayload: ByteArray) {
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

        val service = BluetoothGattService(
            PHANTOM_SVC_UUID,
            BluetoothGattService.SERVICE_TYPE_PRIMARY,
        ).also { it.addCharacteristic(char) }

        gattServer = btManager.openGattServer(context, gattCallback)
            .also { it.addService(service) }
    }

    private fun startAdvertising(msdPayload: ByteArray) {
        val advertiser = btAdapter.bluetoothLeAdvertiser ?: return

        // msdPayload = [0xFF, 0xFF, 0x50, h0, h1, h2, h3, caps]
        // Android addManufacturerData(companyId=0xFFFF, data=[0x50, h0, h1, h2, h3, caps])
        val companyId = 0xFFFF
        val advBytes  = if (msdPayload.size >= 8) msdPayload.drop(2).toByteArray()
                        else byteArrayOf(0x50, 0, 0, 0, 0, 0) // fallback

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
            override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) { /* advertising started */ }
            override fun onStartFailure(errorCode: Int) {
                // Non-fatal — mesh still works via scanning if advertising fails
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
        connectedDevices.clear()
    }

    // ── Notify all connected centrals ─────────────────────────────────────────

    fun notifyAll(data: ByteArray) {
        val server = gattServer ?: return
        val char = server.getService(PHANTOM_SVC_UUID)
            ?.getCharacteristic(PHANTOM_CHAR_UUID) ?: return
        char.value = data
        connectedDevices.toSet().forEach { device ->
            server.notifyCharacteristicChanged(device, char, false)
        }
    }

    // ── GATT server callbacks ─────────────────────────────────────────────────

    private val gattCallback = object : BluetoothGattServerCallback() {

        override fun onConnectionStateChange(
            device: BluetoothDevice,
            status: Int,
            newState: Int,
        ) {
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                connectedDevices.add(device)
            } else {
                connectedDevices.remove(device)
            }
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
            if (responseNeeded) {
                gattServer?.sendResponse(
                    device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null,
                )
            }
            // Forward the raw bytes to Dart as a List<Int>
            channel.invokeMethod("onWrite", value.map { it.toInt() and 0xFF })
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
