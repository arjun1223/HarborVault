// Only generated fixtures; never use a personal .harb file for these tests.
import {readFile} from 'node:fs/promises';
import vm from 'node:vm';
import assert from 'node:assert/strict';
import {webcrypto} from 'node:crypto';
const html=await readFile(new URL('../Web/HarborReader.html',import.meta.url),'utf8');
const core=html.match(/<script id="harbor-core">([\s\S]*?)<\/script>/)[1];
const context=vm.createContext({crypto:webcrypto,TextEncoder,TextDecoder,Uint8Array,DataView,BigInt,Map,Set,atob});
vm.runInContext(core+'\nglobalThis.reader=HarborCore;',context);
const reader=context.reader,dir=new URL('../output/browser-fixtures/',import.meta.url);
const fixture=JSON.parse(await readFile(new URL('fixture.json',dir),'utf8'));
const bytes=async name=>new Uint8Array(await readFile(new URL(name,dir)));
let checks=0;const check=(value,label)=>{assert.ok(value,label);console.log('PASS '+(++checks)+': '+label);};
async function rejects(action,label){await assert.rejects(action);console.log('PASS '+(++checks)+': '+label);}
const enc=new TextEncoder(),dec=new TextDecoder(),number=b=>Number(new DataView(b.buffer,b.byteOffset,8).getBigUint64(0));
const u64=n=>{const b=new Uint8Array(8);new DataView(b.buffer).setBigUint64(0,BigInt(n));return b;};
const concat=(...parts)=>{const b=new Uint8Array(parts.reduce((s,p)=>s+p.length,0));let at=0;for(const p of parts){b.set(p,at);at+=p.length;}return b;};
const nativeMan=fixture.manifest.items;
for(const [file,key] of [['legacy.harb',fixture.legacyKey],['hardened.harb',fixture.hardenedKey]]){
  const session=await reader.open(await bytes(file),key);
  check(session.name==='Browser fixture'&&session.items.length===nativeMan.length,file+' opens the native Mac export');
  check(session.items.filter(i=>i.isFolder).length===2,file+' preserves nested and empty folders');
  for(const item of session.items.filter(i=>!i.isFolder)){
    const plain=await session.read(item.id);
    const expected=nativeMan.find(i=>i.id.toUpperCase()===item.id);
    check(Buffer.from(await webcrypto.subtle.digest('SHA-256',plain)).toString('base64')===expected.digest,file+' verifies original bytes: '+item.name);
    if(item.name==='multi.bin')check(plain.length===4*1024*1024+119&&plain.every((v,i)=>v===i%251),'chunked file decrypts across the 4 MiB boundary');
    if(item.name==='empty.bin')check(plain.length===0,'empty file authenticates');
    plain.fill(0);
  }
  const id=session.items.find(i=>!i.isFolder).id;
  session.close();await rejects(()=>session.read(id),'locked session cannot decrypt more files');
  await rejects(async()=>reader.open(await bytes(file),'HARB-'+'00'.repeat(32)),file+' rejects an incorrect sharing key');
}
const publicSession=await reader.open(await bytes('public.harb'),'');
check(publicSession.isPublic && publicSession.items.length===nativeMan.length,'public Mac exports open without any sharing key');
const publicText=await publicSession.read(publicSession.items.find(i=>i.name==='hello.txt').id);
check(dec.decode(publicText).startsWith('Harbor browser compatibility fixture.'),'public exports preserve verified original contents');publicText.fill(0);publicSession.close();
const badPublic=await bytes('public.harb');badPublic[8]^=1;
await rejects(()=>reader.open(badPublic,''),'public exports reject a damaged embedded decoding key');
const badPublicPayload=await bytes('public.harb');badPublicPayload[badPublicPayload.length-1]^=1;
await rejects(()=>reader.open(badPublicPayload,''),'public exports reject damaged envelope contents');
const fakePublic=concat(enc.encode('HARBPB01'),new Uint8Array(32),await bytes('hardened.harb'));
await rejects(()=>reader.open(fakePublic,''),'adding a public marker cannot bypass a private export’s sharing key');
await rejects(async()=>reader.open(await bytes('hardened.harb'),''),'private exports still require the separate sharing key');
const keyText=await reader.unlockSavedKey(await bytes('fixture.harbkey'),fixture.keyFilePassword);
check(keyText===fixture.hardenedKey,'browser opens native password-encrypted .harbkey');
await rejects(async()=>reader.unlockSavedKey(await bytes('fixture.harbkey'),'bad password'),'saved keys reject incorrect passwords');
for(const offset of [8,40,48,48+1048576+27]){
  const damaged=await bytes('hardened.harb');damaged[offset]^=1;
  await rejects(()=>reader.open(damaged,fixture.hardenedKey),'v2 rejects corruption at byte '+offset);
}
const reordered=await bytes('hardened.harb'),block=1048576+28;
const first=reordered.slice(48,48+block);reordered.copyWithin(48,48+block,48+block*2);reordered.set(first,48+block);
await rejects(()=>reader.open(reordered,fixture.hardenedKey),'v2 rejects reordered encrypted records');
for(const file of ['legacy.harb','hardened.harb']){
  const truncated=(await bytes(file)).slice(0,-1);await rejects(()=>reader.open(truncated,file==='legacy.harb'?fixture.legacyKey:fixture.hardenedKey),file+' rejects truncation');
  const extra=concat(await bytes(file),new Uint8Array([0]));await rejects(()=>reader.open(extra,file==='legacy.harb'?fixture.legacyKey:fixture.hardenedKey),file+' rejects trailing data');
}
const raw=await bytes('legacy.harb'),metaSize=number(raw.subarray(44,52)),packageID=dec.decode(raw.subarray(8,44));
const rawKey=Uint8Array.from(fixture.legacyKey.replace(/^HARB-/,'').replace(/-/g,'').match(/../g),h=>parseInt(h,16));
const aesKey=await webcrypto.subtle.importKey('raw',rawKey,'AES-GCM',false,['encrypt','decrypt']);rawKey.fill(0);
const aad=enc.encode('harb/catalog/'+packageID),sealed=raw.subarray(52,52+metaSize);
const decoded=await webcrypto.subtle.decrypt({name:'AES-GCM',iv:sealed.subarray(0,12),additionalData:aad},aesKey,sealed.subarray(12));
const catalog=JSON.parse(dec.decode(decoded));
async function forge(change){const altered=structuredClone(catalog);change(altered);const nonce=webcrypto.getRandomValues(new Uint8Array(12));const ciphertext=new Uint8Array(await webcrypto.subtle.encrypt({name:'AES-GCM',iv:nonce,additionalData:aad},aesKey,enc.encode(JSON.stringify(altered))));const meta=concat(nonce,ciphertext);return concat(raw.subarray(0,44),u64(meta.length),meta,raw.subarray(52+metaSize));}
const originalFormat=await reader.open(await forge(c=>{c.version=1;delete c.sourceID;delete c.exportedAt;}),fixture.legacyKey);
check(originalFormat.items.length===nativeMan.length,'original version-1 catalog remains readable');originalFormat.close();
for(const [label,change] of [
  ['path traversal',c=>c.manifest.items[0].name='../escape'],
  ['duplicate IDs',c=>c.manifest.items[1].id=c.manifest.items[0].id],
  ['nonzero folder size',c=>c.manifest.items.find(i=>i.isFolder).size=Number.MAX_SAFE_INTEGER],
  ['oversized file',c=>c.manifest.items.find(i=>!i.isFolder).size=Number.MAX_SAFE_INTEGER],
  ['folder cycle',c=>{const i=c.manifest.items.find(i=>i.isFolder);i.parent=i.id;}],
  ['missing parent',c=>c.manifest.items[0].parent='00000000-0000-0000-0000-000000000000'],
  ['deleted item',c=>c.manifest.items[0].deletedAt=1],
  ['invalid digest',c=>c.manifest.items.find(i=>!i.isFolder).digest='AA=='],
  ['unsupported catalog',c=>c.version=99],
  ['invalid timestamps',c=>c.manifest.items[0].modified='tomorrow'],
])await rejects(async()=>reader.open(await forge(change),fixture.legacyKey),'authenticated malformed catalog rejects '+label);
// A legitimate sharing-key holder can forge a wrong digest; don't display those bytes.
const wrongHash=await reader.open(await forge(c=>c.manifest.items.find(i=>!i.isFolder).digest=Buffer.alloc(32).toString('base64')),fixture.legacyKey);
await rejects(()=>wrongHash.read(wrongHash.items.find(i=>!i.isFolder).id),'file SHA-256 is checked before returning plaintext');wrongHash.close();
const corrupted=await bytes('legacy.harb');corrupted[corrupted.length-1]^=1;
const brokenSession=await reader.open(corrupted,fixture.legacyKey);let damagedRejected=false;
for(const item of brokenSession.items.filter(i=>!i.isFolder)){try{const p=await brokenSession.read(item.id);p.fill(0);}catch{damagedRejected=true;}}
check(damagedRejected,'modified file ciphertext cannot return readable bytes');brokenSession.close();
const cancelled=await bytes('hardened.harb');let steps=0;
await rejects(()=>reader.open(cancelled,fixture.hardenedKey,()=>{if(++steps>4)throw new Error('locked');}),'lock cancellation discards an in-flight envelope');
check(cancelled.every(v=>v===0),'cancelled open clears its encrypted input buffer');
check(!/innerHTML|outerHTML|insertAdjacentHTML|eval\(|new Function/.test(html),'untrusted names and text are never interpreted as HTML or script');
check(/connect-src 'none'/.test(html)&&!/\bfetch\(|XMLHttpRequest|sendBeacon|localStorage|indexedDB|serviceWorker/.test(html),'standalone reader has no upload or persistent browser storage path');
check(html.includes("document.addEventListener('visibilitychange'")&&html.includes('5*60*1000'),'leaving the tab and idle timeout lock the reader');
new vm.Script(html.match(/<script id="harbor-ui">([\s\S]*?)<\/script>/)[1]);
check(true,'browser UI script parses successfully');
console.log('All '+checks+' browser compatibility and security checks passed.');
