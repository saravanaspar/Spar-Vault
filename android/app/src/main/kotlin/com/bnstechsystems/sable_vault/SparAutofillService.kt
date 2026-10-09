package com.bnstechsystems.sable_vault

import android.app.Activity
import android.app.PendingIntent
import android.app.assist.AssistStructure
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.CancellationSignal
import android.os.SystemClock
import android.service.autofill.*
import android.view.autofill.AutofillId
import android.view.autofill.AutofillValue
import android.widget.RemoteViews
import java.security.MessageDigest
import java.security.SecureRandom

internal data class FillEntry(val id:String,val title:String,val username:String,val password:String,val origin:String,val app:String,val certificates:Set<String>)
internal data class FillTarget(val token:String,val caller:String,val origin:String?,val username:AutofillId?,val password:AutofillId,val expires:Long,val epoch:Long)
// Process-only credentials. No file/prefs/database of plaintext is created.
// Immutable JVM/Dart strings cannot be guaranteed wiped; references are dropped.
internal object AutofillCache {
    private var entries:List<FillEntry> = emptyList()
    private var chrome:Set<String> = emptySet()
    private var deadline=0L
    private var epoch=0L
    private val requests=mutableMapOf<String,FillTarget>()
    @Synchronized fun clear(){entries=emptyList();chrome=emptySet();deadline=0;epoch++;requests.clear()}
    @Synchronized fun update(m:Map<*,*>) {
        val expires=(m["expiresAt"] as? Number)?.toLong()?:0
        val delta=expires-System.currentTimeMillis()
        if(delta<=0||delta>31*60_000){clear();return}
        fun text(v:Any?,limit:Int):String {val s=v as? String?:throw IllegalArgumentException();if(s.length>limit)throw IllegalArgumentException();return s}
        fun certs(v:Any?):Set<String> {val l=v as? List<*>?:throw IllegalArgumentException();if(l.size>8)throw IllegalArgumentException();return l.map{val s=text(it,64);if(!Regex("^[a-f0-9]{64}$").matches(s))throw IllegalArgumentException();s}.toSet()}
        val rows=m["entries"] as? List<*>?:throw IllegalArgumentException();if(rows.size>2000)throw IllegalArgumentException()
        val next=rows.map{raw->val e=raw as? Map<*,*>?:throw IllegalArgumentException();FillEntry(text(e["id"],32),text(e["title"],200),text(e["username"],1000),text(e["password"],4096),text(e["origin"],2000),text(e["package"],200),certs(e["certificates"]))}
        entries=next;chrome=certs(m["chromeCertificates"]);deadline=SystemClock.elapsedRealtime()+delta
        if(next.isEmpty()){epoch++;requests.clear()}
    }
    fun certificates(context:Context,app:String):List<String> {
        if(!Regex("^[A-Za-z0-9_]+(?:\\.[A-Za-z0-9_]+)+$").matches(app))return emptyList()
        return try{val signatures=if(Build.VERSION.SDK_INT>=28)context.packageManager.getPackageInfo(app,PackageManager.GET_SIGNING_CERTIFICATES).signingInfo?.apkContentsSigners else context.packageManager.getPackageInfo(app,PackageManager.GET_SIGNATURES).signatures
            signatures?.map{s->MessageDigest.getInstance("SHA-256").digest(s.toByteArray()).joinToString(""){"%02x".format(it.toInt() and 255)}}?.sorted()?:emptyList()
        }catch(_:Exception){emptyList()}
    }
    @Synchronized fun matches(context:Context,caller:String,origin:String?):List<FillEntry> {
        if(SystemClock.elapsedRealtime()>=deadline){clear();return emptyList()}
        val actual=certificates(context,caller).toSet();if(actual.isEmpty())return emptyList()
        // Android ViewNode strips the port from setWebDomain(). Until a
        // browser provides a verifiable full origin, all web fills fail closed.
        if(origin!=null||caller=="com.android.chrome")return emptyList()
        return entries.filter{it.app==caller&&it.certificates.isNotEmpty()&&it.certificates==actual}
    }
    @Synchronized fun request(caller:String,origin:String?,username:AutofillId?,password:AutofillId):FillTarget {
        requests.entries.removeAll{SystemClock.elapsedRealtime()>=it.value.expires};if(requests.size>=16)requests.clear()
        val bytes=ByteArray(16).also{SecureRandom().nextBytes(it)};val token=bytes.joinToString(""){"%02x".format(it.toInt() and 255)}
        val target=FillTarget(token,caller,origin,username,password,minOf(deadline,SystemClock.elapsedRealtime()+30_000),epoch);requests[token]=target;return target
    }
    @Synchronized fun take(token:String):FillTarget? {val r=requests.remove(token)?:return null;return if(valid(r))r else null}
    @Synchronized fun valid(r:FillTarget)=r.epoch==epoch&&SystemClock.elapsedRealtime()<deadline&&SystemClock.elapsedRealtime()<r.expires
}
class SparAutofillService:AutofillService() {
    override fun onSaveRequest(request:SaveRequest,callback:SaveCallback){callback.onFailure("Save logins explicitly inside Spar Vault.")}
    override fun onFillRequest(request:FillRequest,cancellation:CancellationSignal,callback:FillCallback) {
        try {
            val structure=request.fillContexts.lastOrNull()?.structure?:run{callback.onSuccess(null);return}
            val caller=structure.activityComponent?.packageName?:run{callback.onSuccess(null);return}
            var user:AutofillId?=null;var pass:AutofillId?=null;var nodes=0
            val origins=mutableSetOf<String>();var invalidWeb=false
            fun walk(n:AssistStructure.ViewNode,depth:Int) {
                if(++nodes>3000||depth>40)throw IllegalArgumentException()
                if(!n.webDomain.isNullOrEmpty()){
                    if(Build.VERSION.SDK_INT<28||n.webScheme!="https"){invalidWeb=true}
                    else {val domain=n.webDomain!!;val uri=java.net.URI("https://$domain")
                        if(uri.host==null||uri.userInfo!=null||uri.rawPath.isNotEmpty()||uri.rawQuery!=null||uri.rawFragment!=null||uri.port !in listOf(-1,443)||!Regex("^[A-Za-z0-9.-]+$").matches(domain)){invalidWeb=true}
                        else origins.add("https://${uri.host.lowercase()}")}
                }
                val hints=(n.autofillHints?:emptyArray()).map{it.lowercase()};val html=n.htmlInfo?.attributes?.associate{it.first.lowercase() to it.second.lowercase()}?:emptyMap()
                val autocomplete=html["autocomplete"]?.split(' ')?:emptyList()
                val passwordHint=hints.any{it=="password"||it=="currentpassword"}||autocomplete.contains("current-password")||((n.inputType and 0xfff)==0x81)||((n.inputType and 0xfff)==0xe1)||html["type"]=="password"
                val usernameHint=hints.any{it in listOf("username","emailaddress","email")}||autocomplete.any{it in listOf("username","email")}
                if(n.autofillId!=null){if(passwordHint){if(pass!=null&&pass!=n.autofillId)throw IllegalArgumentException();pass=n.autofillId}else if(usernameHint){if(user==null)user=n.autofillId}}
                for(i in 0 until n.childCount)walk(n.getChildAt(i),depth+1)
            }
            for(i in 0 until structure.windowNodeCount)walk(structure.getWindowNodeAt(i).rootViewNode,0)
            if(cancellation.isCanceled||invalidWeb||origins.size>1||pass==null){callback.onSuccess(null);return}
            val origin=origins.singleOrNull()
            // A Chrome request without an HTTPS origin cannot fall back to a
            // native package binding; ambiguity always fails closed.
            if(caller=="com.android.chrome"&&origin==null){callback.onSuccess(null);return}
            if(AutofillCache.matches(this,caller,origin).isEmpty()){callback.onSuccess(null);return}
            val target=AutofillCache.request(caller,origin,user,pass!!)
            val intent=Intent(this,AutofillConfirmActivity::class.java).putExtra("token",target.token).setData(android.net.Uri.parse("spar-vault://autofill/${target.token}"))
            val pending=PendingIntent.getActivity(this,0,intent,PendingIntent.FLAG_ONE_SHOT or PendingIntent.FLAG_IMMUTABLE)
            val presentation=RemoteViews(packageName,android.R.layout.simple_list_item_1).apply{setTextViewText(android.R.id.text1,"Approve in Spar Vault")}
            val ids=listOfNotNull(user,pass).toTypedArray()
            callback.onSuccess(FillResponse.Builder().setAuthentication(ids,pending.intentSender,presentation).build())
        }catch(_:Exception){callback.onSuccess(null)}
    }
}
