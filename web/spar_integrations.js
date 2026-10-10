'use strict';
window.sparSaveMasterKey=async(input,canSave)=>{
  const bytes=new Uint8Array(input);
  try{
    if(bytes.length>512||!/^[0-9a-f]{64}$/i.test(new TextDecoder('utf-8',{fatal:true}).decode(bytes).replace(/[\s-]/g,'')))throw Error('Invalid key file');
    if(!canSave())return 'cancelled';
    if(typeof window.showDirectoryPicker!=='function'){
      const url=URL.createObjectURL(new Blob([bytes],{type:'text/plain'}));
      try{const link=document.createElement('a');link.href=url;link.download='spar-vault-master-key.txt';link.click();}
      finally{URL.revokeObjectURL(url);}
      return 'download';
    }
    let folder;
    try{folder=await window.showDirectoryPicker({mode:'readwrite',id:'spar-secure-key'});}
    catch(error){if(error.name==='AbortError')return 'cancelled';throw error;}
    if(!canSave())return 'cancelled';
    const file=await folder.getFileHandle('spar-vault-master-key.txt',{create:true});
    const writer=await file.createWritable();
    try{await writer.write(bytes);await writer.close();}
    catch(error){await writer.abort().catch(()=>{});throw error;}
    return 'saved';
  }finally{bytes.fill(0);}
};
// This store contains encrypted snapshots and a granted directory handle only.
const backupDB = () => new Promise((resolve,reject) => {
  const r=indexedDB.open('spar-backups-v1',1);
  r.onupgradeneeded=()=>{r.result.createObjectStore('settings');r.result.createObjectStore('copies');};
  r.onsuccess=()=>resolve(r.result);r.onerror=()=>reject(Error('Backup storage unavailable'));
});
const backupTx = async (store,mode,work) => {
  const db=await backupDB();
  return new Promise((resolve,reject)=>{const tx=db.transaction(store,mode);let result;work(tx.objectStore(store),v=>{result=v;});tx.oncomplete=()=>{db.close();resolve(result);};tx.onerror=tx.onabort=()=>{db.close();reject(Error('Backup storage failed'));};});
};
window.sparBackupChoose=async()=>{
  if(typeof window.showDirectoryPicker==='function'){
    const handle=await window.showDirectoryPicker({mode:'readwrite',id:'spar-encrypted-backups'});
    await backupTx('settings','readwrite',(s)=>s.put(handle,'directory'));
    return 'browser-directory';
  }
  return 'browser-storage'; // UI requires an explicit warning and manual export.
};
window.sparBackupWrite=async(directory,snapshot,id)=>{
  if(!/^[a-f0-9]{32}$/.test(id)||typeof snapshot!=='string'||snapshot.length>33554432)throw Error('Invalid encrypted backup');
  const prefix=`spar-auto-${id}-`,name=`${prefix}${Date.now().toString().padStart(16,'0')}-${crypto.randomUUID()}.svlt`;
  if(directory==='browser-directory'){
    const handle=await backupTx('settings','readonly',(s,set)=>{const r=s.get('directory');r.onsuccess=()=>set(r.result);});
    if(!handle||await handle.queryPermission({mode:'readwrite'})!=='granted')throw Error('Select the backup folder again to grant access');
    const file=await handle.getFileHandle(name,{create:true});const writer=await file.createWritable();
    try{await writer.write(new Blob([snapshot],{type:'application/json'}));await writer.close();}catch(e){await writer.abort().catch(()=>{});throw e;}
    const names=[];for await(const [n,h] of handle.entries()){if(h.kind==='file'&&n.startsWith(prefix)&&/^spar-auto-[a-f0-9]{32}-[0-9]{16}-[a-f0-9-]{36}\.svlt$/.test(n))names.push(n);}
    names.sort().reverse();for(const n of names.slice(5))await handle.removeEntry(n);
  }else if(directory==='browser-storage'){
    await backupTx('copies','readwrite',(s)=>{s.put(snapshot,name);const r=s.getAllKeys();r.onsuccess=()=>{r.result.filter(k=>typeof k==='string'&&k.startsWith(prefix)).sort().reverse().slice(5).forEach(k=>s.delete(k));};});
  }else throw Error('Choose a backup location first');
};
window.sparBackupList=async(id)=>{
  if(!/^[a-f0-9]{32}$/.test(id))throw Error('Invalid vault');
  const keys=await backupTx('copies','readonly',(s,set)=>{const r=s.getAllKeys();r.onsuccess=()=>set(r.result);});
  return JSON.stringify(keys.filter(k=>typeof k==='string'&&k.startsWith(`spar-auto-${id}-`)).sort().reverse());
};
window.sparBackupRead=async(name)=>{
  if(typeof name!=='string'||name.length>160)throw Error('Invalid copy');
  const value=await backupTx('copies','readonly',(s,set)=>{const r=s.get(name);r.onsuccess=()=>set(r.result);});
  if(typeof value!=='string')throw Error('Copy unavailable');return value;
};
