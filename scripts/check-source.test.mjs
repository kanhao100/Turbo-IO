import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {audit} from './check-source.mjs';

function fixture(files,run){
  const root=fs.mkdtempSync(path.join(os.tmpdir(),'turbo-source-audit-'));
  try{for(const [name,value] of Object.entries(files)){const file=path.join(root,name);fs.mkdirSync(path.dirname(file),{recursive:true});fs.writeFileSync(file,value);}run(audit(root));}
  finally{fs.rmSync(root,{recursive:true,force:true});}
}
test('allows blank-key original Android source',()=>{
  fixture({'SecretStore.java':'String apiKey = "";'},r=>assert.deepEqual(r.findings,[]));
});
test('rejects model key without returning the secret',()=>{
  const fake='sk-'+'z'.repeat(24);
  fixture({'settings.json':JSON.stringify({api_key:fake})},r=>{
    assert.ok(r.findings.some(f=>f.rule==='api-key'));
    assert.ok(!JSON.stringify(r).includes(fake));
  });
});
for(const extension of ['apk','dex','jar','jks','keystore','jsonl','hap','har','p12','p7b','cer']){
  test('rejects '+extension+' artifacts',()=>fixture({['sample.'+extension]:'fixture'},r=>assert.ok(r.findings.some(f=>f.rule==='non-source-artifact'))));
}
test('rejects private developer home paths',()=>{
  fixture({'build.sh':'sdk="'+['','Users','sample-person','Library','Android','sdk'].join('/')+'"'},r=>assert.ok(r.findings.some(f=>f.rule==='private-home')));
});
test('rejects Harmony local signing configuration',()=>{
  fixture({'harmony-sdk/build-profile.json5':'{}'},r=>assert.ok(r.findings.some(f=>f.rule==='local-signing-config')));
});
test('weather mock exception is exact and does not hide another tenant on the same line',()=>{
  const name='harmony-sdk/tests/remote-services.test.mjs';
  const mock="'test."+'re.qweatherapi.com'+"'";
  fixture({[name]:mock},r=>assert.deepEqual(r.findings,[]));
  fixture({[name]:mock+"; 'private-fixture."+'re.qweatherapi.com'+"'"},r=>assert.ok(r.findings.some(f=>f.rule==='dedicated-weather-tenant')));
  fixture({'settings.ts':mock},r=>assert.ok(r.findings.some(f=>f.rule==='dedicated-weather-tenant')));
});
test('permits generated build directory without treating it as publishable',()=>{
  fixture({'build/output.dex':'fixture','README.md':'Source only'},r=>{assert.equal(r.files,1);assert.deepEqual(r.findings,[]);});
});

test('animation exception rejects changed pixels or binary data',()=>{
  const root='firmware-research/strix-1.0.4.12/native-navigation/src/official-addon/research/animation-runtime-v1/assets/';
  fixture({[root+'encoded-v1/anime-idle-192x176-l8.bin']:'changed'},r=>assert.ok(r.findings.some(f=>f.rule==='animation-asset-needs-review')));
  fixture({[root+'unreviewed.png']:'unreviewed'},r=>assert.ok(r.findings.some(f=>f.rule==='non-source-artifact')));
});
