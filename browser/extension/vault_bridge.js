'use strict';
// Injected only into the configured vault origin after a permission grant.
if(!globalThis.__sparVaultBridge){
  globalThis.__sparVaultBridge=true;
  chrome.runtime.onMessage.addListener((message,sender,respond)=>{
    if(sender.id!==chrome.runtime.id||message?.source!=='spar-vault-extension'||message.extensionId!==chrome.runtime.id||message.type!=='fill'||!/^[a-f0-9]{32}$/.test(message.nonce))return false;
    const nonce=message.nonce,origin=location.origin;
    const finish=()=>{window.removeEventListener('message',listener);clearTimeout(timer);};
    const listener=e=>{const d=e.data;if(e.source!==window||e.origin!==origin||d?.source!=='spar-vault-response'||d.nonce!==nonce||d.origin!==message.origin)return;finish();respond(d);};
    const timer=setTimeout(()=>{finish();respond({error:'Vault approval expired'});},45000);
    window.addEventListener('message',listener);window.postMessage(message,origin);return true;
  });
}
