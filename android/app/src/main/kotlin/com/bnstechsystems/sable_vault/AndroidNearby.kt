package com.bnstechsystems.sable_vault

import android.app.Activity
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel
import java.util.ArrayDeque
import java.net.Inet4Address

class AndroidNearby(private val activity: Activity) {
    private val manager = activity.getSystemService(NsdManager::class.java)
    private val handler = Handler(Looper.getMainLooper())
    private var registration: NsdManager.RegistrationListener? = null
    private var registering: MethodChannel.Result? = null
    private var discovery: NsdManager.DiscoveryListener? = null
    private var scanning: MethodChannel.Result? = null
    private var epoch = 0
    private var lock: WifiManager.MulticastLock? = null
    private var scanLock: WifiManager.MulticastLock? = null
    private val serviceType = "_sparvault._tcp."
    private fun acquire(tag: String): WifiManager.MulticastLock = activity.applicationContext.getSystemService(WifiManager::class.java)
        .createMulticastLock(tag).apply { setReferenceCounted(false); acquire() }
    private fun release(value: WifiManager.MulticastLock?) { try { if(value?.isHeld==true)value.release() } catch (_: Exception) {} }
    fun advertise(values: Map<*, *>, result: MethodChannel.Result) {
        stopAdvertisement()
        try {
            val port = values["port"] as Int
            val id = values["id"] as String
            val key = values["public"] as String
            val name = values["name"] as String
            if(port !in 1024..65535 || !Regex("^[a-f0-9]{32}$").matches(id) || android.util.Base64.decode(key,android.util.Base64.URL_SAFE).size!=32 || name.length !in 1..80) throw IllegalArgumentException()
            lock = acquire("spar-vault-receive")
            val listener = object: NsdManager.RegistrationListener {
                override fun onServiceRegistered(info: NsdServiceInfo) { handler.post { if(registration === this) { registering?.success(null);registering=null } } }
                override fun onRegistrationFailed(info: NsdServiceInfo, error: Int) { handler.post { if(registration === this) {
                    registration=null; val pending=registering;registering=null;release(lock);lock=null
                    pending?.error("discovery","Could not advertise this receiver. Connect to Wi-Fi or a hotspot and retry.",null)
                } } }
                override fun onServiceUnregistered(info: NsdServiceInfo) {}
                override fun onUnregistrationFailed(info: NsdServiceInfo,error: Int) {}
            }
            registration = listener;registering=result
            manager.registerService(NsdServiceInfo().apply {
                serviceName="Spar Vault ${id.take(8)}";setServiceType(serviceType);setPort(port)
                setAttribute("id",id);setAttribute("public",key);setAttribute("name",name);setAttribute("version","2")
            },NsdManager.PROTOCOL_DNS_SD,listener)
            handler.postDelayed({ if(registering === result) { stopAdvertisement() } },7000)
        } catch (_: Exception) {
            if(registering === result) { registering=null;stopAdvertisement() }
            else { release(lock);lock=null }
            result.error("discovery","Android could not advertise this receiver. Check local network permission.",null)
        }
    }
    fun scan(result: MethodChannel.Result) {
        if(scanning!=null) { result.error("busy","A device search is already running.",null);return }
        val generation=++epoch;scanning=result
        val found=linkedMapOf<String,Map<String,Any>>()
        val queue=ArrayDeque<NsdServiceInfo>();var resolving=false
        fun finish() {
            if(epoch!=generation || scanning!==result)return
            epoch++;scanning=null
            discovery?.let { try { manager.stopServiceDiscovery(it) } catch (_: Exception) {} };discovery=null
            release(scanLock);scanLock=null
            result.success(found.values.toList())
        }
        fun resolveNext() {
            if(epoch!=generation || resolving || queue.isEmpty())return
            resolving=true
            try { manager.resolveService(queue.removeFirst(),object:NsdManager.ResolveListener {
                override fun onResolveFailed(info:NsdServiceInfo,error:Int) { handler.post { if(epoch==generation) { resolving=false;resolveNext() } } }
                override fun onServiceResolved(info:NsdServiceInfo) { handler.post {
                    if(epoch!=generation)return@post
                    try {
                        fun text(key:String)=info.attributes[key]?.toString(Charsets.UTF_8)?:""
                        val id=text("id");val key=text("public");val name=text("name")
                        val host=if(Build.VERSION.SDK_INT>=34)info.hostAddresses.firstOrNull { it is Inet4Address }?.hostAddress else info.host?.hostAddress
                        if(text("version")=="2" && Regex("^[a-f0-9]{32}$").matches(id) && key.length in 1..44 && name.length in 1..80 && found.size<32)
                            found[id]=mapOf("id" to id,"public" to key,"name" to name,"host" to (host?:""),"port" to info.port)
                    } catch (_: Exception) {}
                    resolving=false;resolveNext()
                } }
            }) } catch (_: Exception) { resolving=false;resolveNext() }
        }
        val listener=object:NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(type:String) {}
            override fun onDiscoveryStopped(type:String) {}
            override fun onStartDiscoveryFailed(type:String,error:Int) { handler.post { finish() } }
            override fun onStopDiscoveryFailed(type:String,error:Int) {}
            override fun onServiceLost(info:NsdServiceInfo) {}
            override fun onServiceFound(info:NsdServiceInfo) { handler.post {
                if(epoch==generation && info.serviceType.trimEnd('.')==serviceType.trimEnd('.') && queue.size<32) { queue.add(info);resolveNext() }
            } }
        }
        discovery=listener
        try { scanLock=acquire("spar-vault-search"); manager.discoverServices(serviceType,NsdManager.PROTOCOL_DNS_SD,listener);handler.postDelayed({finish()},5000) }
        catch (_: Exception) { finish() }
    }
    private fun stopAdvertisement() {
        val listener=registration;registration=null
        val pending=registering;registering=null
        listener?.let { try { manager.unregisterService(it) } catch (_: Exception) {} }
        release(lock);lock=null
        pending?.error("cancelled","Receiver advertisement was cancelled. Try again.",null)
    }
    fun stop() {
        epoch++;scanning?.success(emptyList<Any>());scanning=null
        discovery?.let { try { manager.stopServiceDiscovery(it) } catch (_: Exception) {} };discovery=null
        release(scanLock);scanLock=null
        stopAdvertisement();handler.removeCallbacksAndMessages(null)
    }
}
