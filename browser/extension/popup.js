'use strict';
document.querySelector('#options').onclick=()=>chrome.runtime.openOptionsPage();
document.querySelector('#fill').onclick=async()=>{const status=document.querySelector('#status');status.textContent='Waiting for approval in Spar Vault…';try{const r=await chrome.runtime.sendMessage({type:'request-fill'});status.textContent=r?.ok?'Filled. Submit the form yourself.':r?.error||'Request failed';}catch(_){status.textContent='Connection unavailable. Check integration options.';}};
