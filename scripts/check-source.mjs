#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';

// Exact, visually reviewed documentation captures, not a blanket PNG exclusion.
const reviewedScreenshots = new Map([
  ['harmony-sdk/entry/src/main/resources/base/media/rayneo_home_hero.png', '426720b141311bc859bc59f31763790250a898ef974708d0e69e4841180c51b1'], // Reviewed synthetic glasses illustration, no account/device screenshot.
  ['official-addon/docs/home-tabs-glass-light.png', '12c74fe54a48d2f6b4b5371381f7308732f8b35b07465ecf29728f33dbc969b4'],
  ['official-addon/docs/home-tabs-glass-dark.png', '2f14655122697a4dd0870147fb6bf71417f8dfea82a45670443e2dd1e13c9407'],
  ['official-addon/docs/navigation-search.png', 'd6a4dcb745bd87e67884fa686d87d033d9b557bd70a31cea4fc8098f7935245c'],
  ['official-addon/docs/model-preview.png', '01e013c04f3b0841e4a7ef1ca83af89585154f562c23cfa71698ede373eb4f79'],
  ['official-addon/docs/knowledge-preview.png', 'bb7acde21eddf1c5f83eb02b48cddf2228ad913796fe76f8f5187297a49eb5e7'],
  ['official-addon/docs/profile-preview.png', '567cad6092cc82c543f2c01061615a2ae5e4f491bfd486ee11669dffb5db91b6'],
  ['docs/screenshots/app-home.png', 'ec995e6a4212b0f39c2114369f7264200c13fe84e81210fca34cf8cfbb7d41d9'],
  ['docs/screenshots/app-tools.png', '8d0ae97490dea2d772196ca529b3a9fb82dc4966d66ad1ab8ea4e5ef1befa2e1'],
  ['docs/screenshots/web-chat.png', '61d132ff1b925e158560b3c11aa27f6403be5d6d8a71c5e6fff547cbbc104423'],
  ['docs/screenshots/web-menu.png', '62d9a269e8119d99b30ae7a6592544f9279d53d552d9a8b08baa0d2eee4af3dd'],
]);
// Exact upstream Opus generated weight tables. Still scan their text for credentials.
const reviewedLargeSources = new Map([
  ['core-probe/Vendor/opus-1.5.2/dnn/dred_rdovae_dec_data.c','639d15d2644043d4fec7442e9f46b51ab19f639420e7d57859609c6ecdb24abf'],
  ['core-probe/Vendor/opus-1.5.2/dnn/dred_rdovae_enc_data.c','2831f195a9a2a6d937084bb49b65e6beabb270ac16a08c20721775fc6cac04b5'],
  ['core-probe/Vendor/opus-1.5.2/dnn/fargan_data.c','a1939c859a41f4352ad427fa0fa3348306fdd6cfd64a9bf6493bae96b322d323'],
  ['core-probe/Vendor/opus-1.5.2/dnn/nolace_data.c','5df145d3850d48a89eb27a8512970fde76a401ebf19055f2d7c29213aef7ef04'],
]);

// Values are never printed. Regex scanning is a release gate, not a guarantee.
export function audit(root){
  const findings=[];let files=0;
  const rules=[
    ['api-key',/sk-[A-Za-z0-9_.-]{12,}/],
    ['private-key',/-----BEGIN (?:[A-Z ]+)?PRIVATE KEY-----/],
    ['private-home',/\/Users\/(?!YOUR_|example)[^/\s]+\//],
    ['dedicated-asr-tenant',/llm-[a-z0-9-]+\.[a-z0-9.-]*aliyuncs\.com/],
    ['dedicated-weather-tenant',/[a-z0-9]+\.re\.qweatherapi\.com/],
    ['embedded-credential',/(?:api[_-]?key|password|apiToken|access_token)\s*[:=]\s*["'][a-f0-9]{32,}["']/i],
    ['temporary-public-endpoint',/https:\/\/[a-z0-9-]+\.trycloudflare\.com/],
  ];
  function walk(p){
    if(path.basename(p)==='.git')return; // Also support Git worktree pointer files.
    const s=fs.lstatSync(p),relative=path.relative(root,p).split(path.sep).join('/');
    if(s.isSymbolicLink()){findings.push({file:relative,rule:'symlink'});return;}
    if(s.isDirectory()){
      if(['.git','.build','node_modules','build'].includes(path.basename(p)))return;
      if(/\.(?:app|xcframework|xcresult)$/.test(p)){findings.push({file:relative,rule:'binary-bundle'});return;}
      for(const n of fs.readdirSync(p))walk(path.join(p,n));return;
    }
    files++;
    if(reviewedScreenshots.has(relative)){
      const digest=createHash('sha256').update(fs.readFileSync(p)).digest('hex');
      if(digest!==reviewedScreenshots.get(relative))findings.push({file:relative,rule:'screenshot-needs-privacy-review'});
      return;
    }
    const dependency=/^core-probe\/Frameworks\/(?:RayneoNet|CocoaAsyncSocket|OpenSSL|RayneoLog|SwiftProtobuf|CocoaLumberjack|SSZipArchive)\.framework\//.test(relative) || relative==='core-probe/Vendor/opus-ios/libopus.a';
    if(dependency)return; // Explicit binary build dependencies; reviewed via the hash inventory.
    if(/\.(?:ipa|apk|hap|har|app|dex|jar|jks|keystore|a|o|dylib|so|p12|p7b|cer|pem|key|mobileprovision|wav|ogg|pcm|mp3|m4a|png|jpg|zip|log|jsonl)$/i.test(p))findings.push({file:relative,rule:'non-source-artifact'});
    if(relative==='harmony-sdk/build-profile.json5')findings.push({file:relative,rule:'local-signing-config'});
    const b=fs.readFileSync(p);if(b.includes(0)){findings.push({file:relative,rule:'binary-content'});return;}
    // Git may check text sources out with CRLF on Windows; compare their canonical LF bytes.
    const canonical=b.toString('utf8').replaceAll('\r\n','\n');
    if(s.size>2*1024*1024 && (!reviewedLargeSources.has(relative)||createHash('sha256').update(canonical).digest('hex')!==reviewedLargeSources.get(relative))){findings.push({file:relative,rule:'oversize-review'});return;}
    canonical.split('\n').forEach((line,i)=>{for(const [rule,re]of rules){
      // One synthetic host in mocked HTTP tests; still scan the rest of that line.
      const checked=rule==='dedicated-weather-tenant' && relative==='harmony-sdk/tests/remote-services.test.mjs'
        ? line.replaceAll("'test." + "re.qweatherapi.com'", "'mock-weather-host'") : line;
      if(re.test(checked))findings.push({file:relative,line:i+1,rule});
    }});
  }
  walk(root);return {files,findings};
}
if(process.argv[1] && path.resolve(process.argv[1])===fileURLToPath(import.meta.url)){
  const root=path.resolve(process.argv[2]||path.join(path.dirname(fileURLToPath(import.meta.url)),'..'));
  const result=audit(root);console.log(JSON.stringify(result,null,2));process.exitCode=result.findings.length?1:0;
}
