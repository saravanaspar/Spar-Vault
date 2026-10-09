'use strict';
const nonce=()=>Array.from(crypto.getRandomValues(new Uint8Array(16)),n=>n.toString(16).padStart(2,'0')).join('');
const httpsOrigin=url=>{const u=new URL(url);if(u.protocol!=='https:'||u.username||u.password)throw Error('Autofill requires HTTPS');return u.origin;};
const nativeRequest=message=>new Promise((resolve,reject)=>{
  chrome.runtime.sendNativeMessage('com.bnstechsystems.spar_vault',message,r=>{
    if(chrome.runtime.lastError)reject(Error('Open Spar Vault and install its native messaging host.'));
    else if(!r||r.error)reject(Error('Autofill refused, cancelled or session expired.'));else resolve(r);
  });
});
async function webRequest(message,settings){
  const url=new URL(settings.vaultUrl);if(url.protocol!=='https:'&&!(url.protocol==='http:'&&['localhost','127.0.0.1'].includes(url.hostname)))throw Error('Set a secure vault URL in extension options');
  const tabs=await chrome.tabs.query({});const vault=tabs.find(t=>{try{return new URL(t.url).origin===url.origin&&new URL(t.url).pathname===url.pathname;}catch(_){return false;}});
  if(!vault)throw Error('Open and unlock your configured Spar Vault tab first.');
  await chrome.scripting.executeScript({target:{tabId:vault.id},files:['vault_bridge.js']});
  return await chrome.tabs.sendMessage(vault.id,{...message,source:'spar-vault-extension',extensionId:chrome.runtime.id,type:'fill'});
}
function fillPage(expected,username,password){
  if(location.origin!==expected||location.protocol!=='https:')return false;
  const visible=e=>e instanceof HTMLInputElement&&!e.disabled&&!e.readOnly&&e.getClientRects().length>0&&getComputedStyle(e).visibility!=='hidden';
  const passwordFields=[...document.querySelectorAll('input[type=password]')].filter(visible).filter(e=>!['new-password','one-time-code'].includes(e.autocomplete));
  if(passwordFields.length!==1)return false;
  const p=passwordFields[0],form=p.form;
  if(form&&new URL(form.getAttribute('action')||location.href,location.href).origin!==expected)return false;
  const scope=form||document;
  const user=[...scope.querySelectorAll('input')].filter(visible).filter(e=>['email','text'].includes(e.type)).find(e=>e.autocomplete==='username'||e.type==='email'||/user|email|login/i.test(e.name+' '+e.id));
  const setter=Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set;
  if(user){setter.call(user,username);user.dispatchEvent(new Event('input',{bubbles:true}));user.dispatchEvent(new Event('change',{bubbles:true}));}
  setter.call(p,password);p.dispatchEvent(new Event('input',{bubbles:true}));p.dispatchEvent(new Event('change',{bubbles:true}));return true;
}
chrome.runtime.onMessage.addListener((message,sender,respond)=>{
  if(sender.id!==chrome.runtime.id||sender.tab||message?.type!=='request-fill')return false;
  (async()=>{
    const [tab]=await chrome.tabs.query({active:true,currentWindow:true});if(!tab?.id)throw Error('Select a login tab');
    const origin=httpsOrigin(tab.url),id=nonce(),settings=await chrome.storage.local.get({mode:'native',vaultUrl:''});
    const request={origin,nonce:id},reply=settings.mode==='web'?await webRequest(request,settings):await nativeRequest(request);
    if(reply?.nonce!==id||reply.origin!==origin||typeof reply.username!=='string'||typeof reply.password!=='string'||reply.username.length>1000||reply.password.length>4096)throw Error('Autofill was refused or cancelled');
    const current=await chrome.tabs.get(tab.id);if(httpsOrigin(current.url)!==origin)throw Error('The target tab changed; retry');
    const results=await chrome.scripting.executeScript({target:{tabId:tab.id,frameIds:[0]},func:fillPage,args:[origin,reply.username,reply.password]});
    // Credentials are never written to extension storage or logs.
    reply.username='';reply.password='';
    if(!results[0]?.result)throw Error('Ambiguous form or cross-origin action. Copy the login manually.');
    respond({ok:true});
  })().catch(e=>respond({error:e.message}));
  return true;
});
