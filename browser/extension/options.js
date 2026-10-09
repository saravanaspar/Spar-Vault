'use strict';
document.querySelector('#id').textContent=chrome.runtime.id;
chrome.storage.local.get({mode:'native',vaultUrl:''}).then(s=>{document.querySelector('#mode').value=s.mode;document.querySelector('#url').value=s.vaultUrl;});
document.querySelector('#save').onclick=async()=>{
  const status=document.querySelector('#status');try{
    const mode=document.querySelector('#mode').value,vaultUrl=document.querySelector('#url').value.trim();
    if(mode==='web'){
      const u=new URL(vaultUrl);if(u.username||u.password||(u.protocol!=='https:'&&!(u.protocol==='http:'&&['localhost','127.0.0.1'].includes(u.hostname))))throw Error('Use HTTPS or a localhost development URL');
      const pattern=`${u.protocol}//${u.hostname}/*`;if(!await chrome.permissions.request({origins:[pattern]}))throw Error('Vault origin permission denied');
      const granted=await chrome.permissions.getAll();const stale=(granted.origins||[]).filter(p=>p!==pattern);if(stale.length)await chrome.permissions.remove({origins:stale});
    }else{const granted=await chrome.permissions.getAll();if(granted.origins?.length)await chrome.permissions.remove({origins:granted.origins});}
    await chrome.storage.local.set({mode,vaultUrl});status.textContent='Saved. Keep your vault unlocked for confirmed autofill.';
  }catch(e){status.textContent=e.message;}
};
