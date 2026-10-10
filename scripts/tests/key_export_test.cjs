const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');

const source = fs.readFileSync(path.join(__dirname, '../../web/spar_integrations.js'), 'utf8');
const key = value => new TextEncoder().encode((value.repeat(8) + ' ').repeat(8).trim() + '\n');
function environment(window, extras = {}) {
  const context = vm.createContext({window, Uint8Array, TextDecoder, Blob, ...extras});
  vm.runInContext(source, context);
  return window;
}
function folder() {
  const files = new Map();
  let fail = false;
  return {files, failNext() { fail = true; }, async getFileHandle(name) {
    return {async createWritable() {
      let staged;
      return {
        async write(bytes) {
          if (fail) { fail = false; throw Error('Synthetic disk error'); }
          staged = Buffer.from(bytes);
        },
        async close() { files.set(name, staged); },
        async abort() { staged = undefined; },
      };
    }};
  }};
}

test('same folder replaces one exact key file; different folders keep independent copies', async () => {
  const first = folder(), second = folder(); let selected = first;
  const app = environment({showDirectoryPicker: async () => selected});
  const old = key('1'), next = key('2');
  assert.equal(await app.sparSaveMasterKey(old, () => true), 'saved');
  selected = second; await app.sparSaveMasterKey(old, () => true);
  selected = first; await app.sparSaveMasterKey(next, () => true);
  assert.equal(first.files.size, 1);
  assert.deepEqual(first.files.get('spar-vault-master-key.txt'), Buffer.from(next));
  assert.deepEqual(second.files.get('spar-vault-master-key.txt'), Buffer.from(old));
  assert.deepEqual(next, key('2')); // The caller owns its input; only the JS copy is wiped.
});
test('cancelled and late selections do not create files', async () => {
  const selected = folder(); let current = true;
  const app = environment({showDirectoryPicker: async () => { current = false; return selected; }});
  assert.equal(await app.sparSaveMasterKey(key('3'), () => current), 'cancelled');
  assert.equal(selected.files.size, 0);
  app.showDirectoryPicker = async () => { const error = Error('cancelled'); error.name = 'AbortError'; throw error; };
  assert.equal(await app.sparSaveMasterKey(key('3'), () => true), 'cancelled');
});
test('failed replacement aborts the writer and retains the previous key', async () => {
  const selected = folder(), app = environment({showDirectoryPicker: async () => selected});
  await app.sparSaveMasterKey(key('4'), () => true); selected.failNext();
  await assert.rejects(app.sparSaveMasterKey(key('5'), () => true), /Synthetic disk error/);
  assert.deepEqual(selected.files.get('spar-vault-master-key.txt'), Buffer.from(key('4')));
});
test('invalid keys are rejected before requesting folder access', async () => {
  const app = environment({showDirectoryPicker: async () => { throw Error('Picker must not open'); }});
  await assert.rejects(app.sparSaveMasterKey(new Uint8Array([1]), () => true), /Invalid key file/);
});
test('browsers without folder support report a download and release its URL', async () => {
  let downloaded = false, revoked = false;
  const app = environment({}, {
    URL: {createObjectURL: () => 'blob:synthetic', revokeObjectURL: () => { revoked = true; }},
    document: {createElement: () => ({click() { assert.equal(this.download, 'spar-vault-master-key.txt'); downloaded = true; }})},
  });
  assert.equal(await app.sparSaveMasterKey(key('6'), () => true), 'download');
  assert.ok(downloaded && revoked);
});
