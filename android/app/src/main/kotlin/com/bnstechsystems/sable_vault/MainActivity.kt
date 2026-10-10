package com.bnstechsystems.sable_vault

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.DocumentsContract
import android.provider.Settings
import android.view.WindowManager
import android.view.autofill.AutofillManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val biometric by lazy { BiometricKey(this) }
    private val deviceLock by lazy { BiometricKey(this, true) }
    private val qr by lazy { AndroidQr(this) }
    private val nearby by lazy { AndroidNearby(this) }
    private var networkResult: MethodChannel.Result?=null
    private var directoryResult: MethodChannel.Result?=null
    private var autofillResult: MethodChannel.Result?=null
    private var setupResult: MethodChannel.Result?=null
    private var setupDeviceLock=false
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
    }
    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        MethodChannel(engine.dartExecutor.binaryMessenger,"spar/integrations").setMethodCallHandler { call,result ->
            try {
                when(call.method) {
                    "biometricAvailable"->result.success(biometric.available())
                    "biometricEnabled"->result.success(biometric.enabled(call.argument<String>("vaultId")?:""))
                    "deviceSecurityStatus"->result.success(mapOf("biometric" to biometric.status(),"screenLock" to deviceLock.status(),"autofillSupported" to autofillSupported(),"autofillSelected" to autofillSelected()))
                    "deviceName"->result.success(deviceName())
                    "installedApps"->result.success(installedApps())
                    "scanTotpQr"->qr.scan(false,result)
                    "readTotpQrImage"->qr.scan(true,result)
                    "nearbyAdvertise"->nearby.advertise(call.arguments as Map<*,*>,result)
                    "nearbyScan"->nearby.scan(result)
                    "nearbyStop"->{nearby.stop();result.success(null)}
                    "deviceUnlockEnabled"->result.success(deviceLock.enabled(call.argument<String>("vaultId")?:""))
                    "enableBiometric", "enableDeviceUnlock"->{val bytes=call.argument<ByteArray>("key")?:byteArrayOf();if(biometric.prompting||deviceLock.prompting){bytes.fill(0);result.error("busy","An Android authentication prompt is already open.",null)}else (if(call.method=="enableDeviceUnlock")deviceLock else biometric).enable(call.argument<String>("vaultId")?:"",bytes,result)}
                    "unlockBiometric", "unlockDevice"->{if(biometric.prompting||deviceLock.prompting)result.error("busy","An Android authentication prompt is already open.",null)else (if(call.method=="unlockDevice")deviceLock else biometric).unlock(call.argument<String>("vaultId")?:"",result)}
                    "cancelBiometric"->{biometric.dispose();deviceLock.dispose();result.success(null)}
                    "clearBiometric"->{biometric.clear();result.success(null)}
                    "clearDeviceUnlock"->{deviceLock.clear();result.success(null)}
                    "requestAuthenticationSetup"->requestAuthenticationSetup(call.argument<Boolean>("deviceLock")==true,result)
                    "packageCertificates"->result.success(AutofillCache.certificates(this,call.argument<String>("package")?:""))
                    "updateAutofill"->{if(autofillSelected())AutofillCache.update(call.arguments as Map<*,*>)else AutofillCache.clear();result.success(null)}
                    "clearAutofill"->{AutofillCache.clear();result.success(null)}
                    "localNetworkPermission"->{val permission="android.permission.ACCESS_LOCAL_NETWORK";if(android.os.Build.VERSION.SDK_INT<37||checkSelfPermission(permission)==android.content.pm.PackageManager.PERMISSION_GRANTED)result.success(true)else {if(networkResult!=null)throw IllegalStateException();networkResult=result;requestPermissions(arrayOf(permission),4102)}}
                    "requestAutofill"->requestAutofill(result)
                    "chooseBackupDirectory", "chooseKeyDirectory"->{if(directoryResult!=null)throw IllegalStateException();directoryResult=result;try{startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION),4101)}catch(error:Exception){directoryResult=null;throw error}}
                    "writeMasterKey"->{AndroidKeyFile(contentResolver).write(call.argument<String>("directory")?:"",call.argument<ByteArray>("bytes")?:byteArrayOf());result.success(null)}
                    "writeBackup"->{writeBackup(call.argument<String>("directory")?:"",call.argument<String>("snapshot")?:"",call.argument<String>("vaultId")?:"");result.success(null)}
                    else->result.notImplemented()
                }
            }catch(_:SecurityException){result.error("permission","Android blocked this operation. Review app permissions or select the backup folder again.",null)}
            catch(_:Exception){result.error("failed","Android could not complete this operation. Retry or use your vault password/key or manual backup.",null)}
        }
    }
    private fun autofillSupported() = Build.VERSION.SDK_INT>=26 && getSystemService(AutofillManager::class.java)?.isAutofillSupported==true
    private fun installedApps():List<Map<String,String>> {
        val intent=Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        return packageManager.queryIntentActivities(intent,0).mapNotNull { info ->
            val app=info.activityInfo?.applicationInfo ?: return@mapNotNull null
            if(app.packageName==packageName) return@mapNotNull null
            mapOf("package" to app.packageName,"name" to app.loadLabel(packageManager).toString().replace(Regex("[\\p{Cntrl}]"),"").take(200))
        }.distinctBy{it["package"]}.sortedBy{it["name"]?.lowercase()}.take(2000)
    }
    private fun deviceName():String {
        val name=try{Settings.Global.getString(contentResolver,"device_name")}catch(_:Exception){null}
        return (name ?: "${Build.MANUFACTURER} ${Build.MODEL}").replace(Regex("[\\p{Cntrl}]"),"").trim().take(80).ifEmpty{"Android phone"}
    }
    private fun autofillSelected() = Build.VERSION.SDK_INT>=26 && getSystemService(AutofillManager::class.java)?.hasEnabledAutofillServices()==true
    private fun requestAutofill(result:MethodChannel.Result) {
        if(!autofillSupported()){result.error("unsupported","Android autofill is unavailable or disabled by device policy.",null);return}
        if(autofillSelected()){result.success(true);return}
        if(autofillResult!=null||setupResult!=null){result.error("busy","Android settings are already open.",null);return}
        val intent=Intent(Settings.ACTION_REQUEST_SET_AUTOFILL_SERVICE,Uri.parse("package:$packageName"))
        autofillResult=result
        try{startActivityForResult(intent,4103)}catch(_:android.content.ActivityNotFoundException){
            try{startActivityForResult(Intent(Settings.ACTION_SETTINGS),4103)}catch(_:Exception){autofillResult=null;result.error("settings","Open Android Settings, search Autofill, and select Spar Vault.",null)}
        }catch(_:Exception){autofillResult=null;result.error("settings","Open Android Settings, search Autofill, and select Spar Vault.",null)}
    }
    private fun requestAuthenticationSetup(device:Boolean,result:MethodChannel.Result) {
        if(Build.VERSION.SDK_INT<30){result.error("unsupported","Hardware-bound quick unlock requires Android 11 or newer.",null);return}
        if(setupResult!=null||autofillResult!=null){result.error("busy","Android settings are already open.",null);return}
        val binding=if(device)deviceLock else biometric
        if(binding.available()){result.success(true);return}
        val state=binding.status()
        val intent=if(state=="permission")Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,Uri.parse("package:$packageName"))
            else if(state=="not_enabled")Intent(Settings.ACTION_SECURITY_SETTINGS)
            else Intent(Settings.ACTION_BIOMETRIC_ENROLL).putExtra(Settings.EXTRA_BIOMETRIC_AUTHENTICATORS_ALLOWED,
                android.hardware.biometrics.BiometricManager.Authenticators.BIOMETRIC_STRONG or
                if(device)android.hardware.biometrics.BiometricManager.Authenticators.DEVICE_CREDENTIAL else 0)
        setupResult=result;setupDeviceLock=device
        try{startActivityForResult(intent,4104)}catch(_:android.content.ActivityNotFoundException){
            try{startActivityForResult(Intent(Settings.ACTION_SECURITY_SETTINGS),4104)}catch(_:Exception){setupResult=null;result.error("settings","Open Android Security settings and configure your fingerprint or screen lock, then retry.",null)}
        }catch(_:Exception){setupResult=null;result.error("settings","Open Android Security settings and configure your fingerprint or screen lock, then retry.",null)}
    }
    override fun onActivityResult(requestCode:Int,resultCode:Int,data:Intent?) {
        super.onActivityResult(requestCode,resultCode,data)
        if(qr.onResult(requestCode,resultCode,data))return
        if(requestCode==4103){val result=autofillResult;autofillResult=null;result?.success(autofillSelected());return}
        if(requestCode==4104){val result=setupResult;setupResult=null;result?.success((if(setupDeviceLock)deviceLock else biometric).available());return}
        if(requestCode==4101){val result=directoryResult;directoryResult=null;val uri=data?.data
            if(resultCode!=Activity.RESULT_OK||uri==null){result?.success(null);return}
            try{contentResolver.takePersistableUriPermission(uri,(data.flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)));result?.success(uri.toString())}catch(_:Exception){result?.error("permission","Folder permission was denied. Select a writable private folder.",null)}
        }
    }
    override fun onRequestPermissionsResult(code:Int,permissions:Array<out String>,grants:IntArray){super.onRequestPermissionsResult(code,permissions,grants);if(code==4102){networkResult?.success(grants.firstOrNull()==android.content.pm.PackageManager.PERMISSION_GRANTED);networkResult=null}}
    private fun writeBackup(directory:String,snapshot:String,id:String) {
        if(!Regex("^[a-f0-9]{32}$").matches(id)||snapshot.length>32*1024*1024||!snapshot.startsWith("{"))throw IllegalArgumentException()
        val tree=Uri.parse(directory)
        if(tree.scheme!="content"||contentResolver.persistedUriPermissions.none{it.uri==tree&&it.isWritePermission&&it.isReadPermission})throw SecurityException()
        val parent=DocumentsContract.buildDocumentUriUsingTree(tree,DocumentsContract.getTreeDocumentId(tree))
        val name="spar-auto-$id-${System.currentTimeMillis().toString().padStart(16,'0')}-${java.util.UUID.randomUUID()}.svlt"
        val created=DocumentsContract.createDocument(contentResolver,parent,"application/json",name)?:throw IllegalStateException()
        try{contentResolver.openOutputStream(created,"wt")?.use{it.write(snapshot.toByteArray(Charsets.UTF_8));it.flush()}?:throw IllegalStateException()}
        catch(e:Exception){try{DocumentsContract.deleteDocument(contentResolver,created)}catch(_:Exception){};throw e}
        val pattern=Regex("^spar-auto-$id-[0-9]{16}-[a-f0-9-]{36}\\.svlt$")
        val children=DocumentsContract.buildChildDocumentsUriUsingTree(tree,DocumentsContract.getTreeDocumentId(tree));val files=mutableListOf<Pair<String,String>>()
        contentResolver.query(children,arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID,DocumentsContract.Document.COLUMN_DISPLAY_NAME,DocumentsContract.Document.COLUMN_MIME_TYPE),null,null,null)?.use{c->while(c.moveToNext()){if(pattern.matches(c.getString(1))&&c.getString(2)!="vnd.android.document/directory")files.add(c.getString(1) to c.getString(0))}}
        files.sortedByDescending{it.first}.drop(5).forEach{DocumentsContract.deleteDocument(contentResolver,DocumentsContract.buildDocumentUriUsingTree(tree,it.second))}
    }
    override fun onDestroy(){nearby.stop();qr.dispose();biometric.dispose();deviceLock.dispose();AutofillCache.clear();directoryResult?.success(null);directoryResult=null;networkResult?.success(false);networkResult=null;autofillResult?.success(false);autofillResult=null;setupResult?.success(false);setupResult=null;super.onDestroy()}
}
