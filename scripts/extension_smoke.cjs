/* Actual Chrome extension background + page injection checks; no real vault. */
const {chromium}=require('playwright');const path=require('path');const fs=require('fs');const os=require('os');const assert=require('assert/strict');
(async()=>{
 const dir=fs.mkdtempSync(path.join(os.tmpdir(),'spar-extension-'));
 const extension=path.resolve('browser/extension');
 const skip=process.env.SPAR_SKIP_EXTENSION_LOAD==='1';
 const context=skip?await(await chromium.launch({headless:true,executablePath:process.env.SPAR_BROWSER_PATH,args:['--no-sandbox']})).newContext():await chromium.launchPersistentContext(dir,{headless:true,executablePath:process.env.SPAR_BROWSER_PATH,args:['--no-sandbox',`--disable-extensions-except=${extension}`,`--load-extension=${extension}`]});
 try{
  let worker;if(!skip){worker=context.serviceWorkers().find(w=>w.url().startsWith('chrome-extension://'));if(!worker)worker=await context.waitForEvent('serviceworker');assert(worker.url().startsWith('chrome-extension://'));}
  const source=fs.readFileSync('browser/extension/background.js','utf8'),start=source.indexOf('function fillPage('),end=source.indexOf('\nchrome.runtime.onMessage',start);const fill=source.slice(start,end);
  const page=await context.newPage();await page.route('https://example.test/**',r=>r.fulfill({contentType:'text/html',body:'<form action="/login"><input name="email" type="email"><input type="password" autocomplete="current-password"></form>'}));await page.goto('https://example.test/login');
  const run=(origin='https://example.test')=>page.evaluate(({fill,origin})=>(0,eval)('('+fill+')')(origin,'synthetic-user','synthetic-password'),{fill,origin});
  assert.equal(await run(),true);assert.equal(await page.locator('input[type=password]').inputValue(),'synthetic-password');
  await page.locator('input[type=password]').fill('');assert.equal(await run('https://example.test:8443'),false);assert.equal(await page.locator('input[type=password]').inputValue(),'');
  await page.locator('form').evaluate(e=>e.action='https://evil.test/');assert.equal(await run(),false);
  await page.locator('form').evaluate(e=>{e.action='/login';e.appendChild(Object.assign(document.createElement('input'),{type:'password'}));});assert.equal(await run(),false);
  if(!skip){const options=await context.newPage(),id=new URL(worker.url()).host;await options.goto(`chrome-extension://${id}/options.html`);assert.equal(await options.locator('#id').textContent(),id);}
  console.log(skip?'PASS actual fill function: HTTPS origin/port, cross-origin action and ambiguous form checks (extension installation not tested)':'PASS extension loads, options ID, HTTPS origin/port, cross-origin action and ambiguous form checks');
 }finally{const browser=context.browser();await context.close();await browser?.close();fs.rmSync(dir,{recursive:true,force:true});}
})().catch(e=>{console.error('Extension check failed:',e.message);process.exitCode=1;});
