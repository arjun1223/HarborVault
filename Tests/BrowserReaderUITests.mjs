// Starts its own headless Chrome profile. Never attaches to the user's browser.
import {spawn} from 'node:child_process';
import {mkdtemp,readFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';
import assert from 'node:assert/strict';
const base=new URL('../',import.meta.url),fixtureDir=new URL('output/browser-fixtures/',base);
const fixture=JSON.parse(await readFile(new URL('fixture.json',fixtureDir),'utf8'));
const profile=await mkdtemp(join(tmpdir(),'harbor-reader-ui-'));
const chrome=spawn('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',[
  '--headless=new','--user-data-dir='+profile,'--no-first-run','--no-default-browser-check',
  '--disable-background-networking','--remote-debugging-port=0','about:blank'
],{stdio:['ignore','ignore','pipe']});
let ws,checks=0;
try{
  const endpoint=await new Promise((resolve,reject)=>{
    let log='';const timeout=setTimeout(()=>reject(new Error('Test browser startup timed out')),20000);
    chrome.once('error',e=>{clearTimeout(timeout);reject(e);});
    chrome.once('exit',()=>{clearTimeout(timeout);reject(new Error('Test browser exited before startup'));});
    chrome.stderr.on('data',b=>{log+=b;const found=log.match(/DevTools listening on (ws:\/\/\S+)/);if(found){clearTimeout(timeout);resolve(new URL(found[1]));}});
  });
  const tabs=await(await fetch('http://'+endpoint.host+'/json/list')).json();
  ws=new WebSocket(tabs.find(t=>t.type==='page').webSocketDebuggerUrl);await new Promise((resolve,reject)=>{ws.onopen=resolve;ws.onerror=reject;});
  let counter=0;const pending=new Map();ws.onmessage=e=>{const m=JSON.parse(e.data);if(m.id){const p=pending.get(m.id);pending.delete(m.id);if(m.error)p.reject(new Error(m.error.message));else p.resolve(m.result);}};
  const call=(method,params={})=>new Promise((resolve,reject)=>{const id=++counter;pending.set(id,{resolve,reject});ws.send(JSON.stringify({id,method,params}));});
  const run=async expression=>{const r=await call('Runtime.evaluate',{expression,awaitPromise:true,returnByValue:true});if(r.exceptionDetails)throw new Error(r.exceptionDetails.exception?.description??r.exceptionDetails.text);return r.result?.value;};
  const check=async(expression,label)=>{assert.ok(await run(expression),label);console.log('PASS '+(++checks)+': '+label);};
  const choose=async(selector,file)=>{const {root}=await call('DOM.getDocument');const {nodeId}=await call('DOM.querySelector',{nodeId:root.nodeId,selector});await call('DOM.setFileInputFiles',{nodeId,files:[fileURLToPath(new URL(file,fixtureDir))]});await run(`document.querySelector(${JSON.stringify(selector)}).dispatchEvent(new Event('change'))`);};
  await call('Page.enable');await call('Runtime.enable');await call('Page.navigate',{url:new URL('Web/HarborReader.html',base).href});
  for(let i=0;i<100;i++){if(await run('document.readyState==="complete" && typeof pick==="function"'))break;await new Promise(r=>setTimeout(r,50));}
  await check('new Set(Array.from(document.querySelectorAll("[id]"),n=>n.id)).size===document.querySelectorAll("[id]").length','page has no duplicate element IDs');
  await check('$("search") instanceof HTMLInputElement','search resolves to the input rather than an SVG symbol');
  for(const [file,key] of [['hardened.harb',fixture.hardenedKey],['legacy.harb',fixture.legacyKey]]){
    await choose('#file',file);await run('$("key").value='+JSON.stringify(key));await run('$("unlockForm").onsubmit({preventDefault(){}})');
    await check('!$("browser").hidden && $("unlockPanel").hidden && session.items.length===6 && $("rows").querySelectorAll(".file").length===1',file+' unlock displays its real root folder');
    await run('$("rows").querySelector(".file").click()');
    await check('$("rows").querySelectorAll(".file").length===5 && $("status").textContent.startsWith("5 items")',file+' opens nested folder and displays every child');
    await run('$("search").value="hello";$("search").dispatchEvent(new Event("input"))');
    await check('$("rows").querySelectorAll(".file").length===1 && $("rows").textContent.includes("hello.txt")','filename search filters the displayed rows');
    await run('show(session.items.find(i=>i.name==="hello.txt"))');
    await check('$("preview").open && $("previewBody").textContent.startsWith("Harbor browser compatibility fixture.")','file opens a verified text preview');
    await run('closePreview();$("allFiles").click()');
    await check('!$("preview").open && session.items.length===6 && $("rows").querySelectorAll(".file").length===1','closing preview and returning to root preserves the session');
    await run('lock()');
    await check('session===null && $("browser").hidden && !$("unlockPanel").hidden && $("rows").children.length===0','locking clears the browser and returns to unlock');
  }
  // Exercise the same FileList path as dragging a key and vault together.
  await choose('#file','hardened.harb');await choose('#keyFile','fixture.harbkey');
  await run('const transfer=new DataTransfer();transfer.items.add($("file").files[0]);transfer.items.add($("keyFile").files[0]);lock();pick(transfer.files)');
  await check('selectedFile?.name==="hardened.harb" && savedKeyFile?.name==="fixture.harbkey" && !$("keyPasswordPanel").hidden','dropping vault and key together retains both selections');
  await run('$("keyPassword").value='+JSON.stringify(fixture.keyFilePassword)+';$("unlockKey").onclick()');
  await run('$("unlockForm").onsubmit({preventDefault(){}})');
  await check('session?.items.length===6 && $("rows").querySelectorAll(".file").length===1','encrypted-key unlock still displays vault files');
  await run('lock()');await choose('#file','public.harb');
  for(let i=0;i<100;i++){if(await run('session?.isPublic===true'))break;await new Promise(r=>setTimeout(r,50));}
  await check('session?.isPublic===true && !$("publicBadge").hidden && $("rows").querySelectorAll(".file").length===1 && $("key").value===""','selecting a public export opens the actual file list automatically without a key');
  await run('$("rows").querySelector(".file").click()');
  await check('$("rows").querySelectorAll(".file").length===5','public copies browse nested folders normally');
  await run('lock()');await choose('#file','hardened.harb');
  await run('$("key").value='+JSON.stringify(fixture.hardenedKey)+';const normalRender=render;render=()=>{throw new Error("Synthetic render failure")};');
  await run('$("unlockForm").onsubmit({preventDefault(){}})');
  await check('session===null && $("browser").hidden && !$("unlockPanel").hidden && $("error").textContent==="Synthetic render failure"','UI errors show an error instead of an apparently empty unlocked vault');
  await run('render=normalRender');
  console.log('All '+checks+' isolated-browser UI checks passed.');
}finally{
  ws?.close();chrome.kill('SIGTERM');
  await new Promise(resolve=>{if(chrome.exitCode!==null||chrome.signalCode!==null)return resolve();chrome.once('exit',resolve);setTimeout(()=>{chrome.kill('SIGKILL');resolve();},3000).unref();});
  await rm(profile,{recursive:true,force:true,maxRetries:5,retryDelay:150});
}
