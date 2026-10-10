package com.bnstechsystems.sable_vault

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.service.autofill.Dataset
import android.service.autofill.FillResponse
import android.view.WindowManager
import android.view.autofill.AutofillManager
import android.view.autofill.AutofillValue
import android.widget.*

class AutofillConfirmActivity:Activity() {
    private val handler=Handler(Looper.getMainLooper())
    override fun onCreate(state:Bundle?) {
        super.onCreate(state);window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
        val request=AutofillCache.take(intent.getStringExtra("token")?:"")?:run{finish();return}
        val matches=AutofillCache.matches(this,request.caller,request.origin)
        if(matches.isEmpty()||!AutofillCache.valid(request)){finish();return}
        val scroll=ScrollView(this);val column=LinearLayout(this).apply{orientation=LinearLayout.VERTICAL;setPadding(32,48,32,32)};scroll.addView(column)
        column.addView(TextView(this).apply{text="Approve Spar Vault autofill\n\n${request.origin?:request.caller}\n\nSelect one saved login. Nothing is submitted automatically.";textSize=18f})
        matches.take(30).forEach{entry->column.addView(Button(this).apply{text="${entry.title}\n${entry.username}";setOnClickListener{
            try {
                if(!AutofillCache.valid(request)||AutofillCache.matches(this@AutofillConfirmActivity,request.caller,request.origin).none{it.id==entry.id&&it==entry}){finish();return@setOnClickListener}
                val presentation=RemoteViews(packageName,android.R.layout.simple_list_item_1).apply{setTextViewText(android.R.id.text1,entry.title)}
                val dataset=Dataset.Builder(presentation).setValue(request.password,AutofillValue.forText(entry.password))
                request.username?.let{dataset.setValue(it,AutofillValue.forText(entry.username))}
                val response=FillResponse.Builder().addDataset(dataset.build()).build()
                setResult(RESULT_OK,Intent().putExtra(AutofillManager.EXTRA_AUTHENTICATION_RESULT,response));finish()
            }catch(_:Exception){finish()}
        }})}
        column.addView(Button(this).apply{text="Cancel";setOnClickListener{finish()}});setContentView(scroll)
        handler.postDelayed({finish()},30_000)
    }
    override fun onDestroy(){handler.removeCallbacksAndMessages(null);super.onDestroy()}
}
