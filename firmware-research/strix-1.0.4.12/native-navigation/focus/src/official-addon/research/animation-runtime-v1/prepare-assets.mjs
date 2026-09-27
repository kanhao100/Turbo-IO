// Mechanical spritesheet slicing/resampling and L8 firmware encoding. No AI calls.
import {execFileSync} from 'node:child_process';
import {readFileSync,writeFileSync,mkdirSync,existsSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {dirname,join,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
const here=dirname(fileURLToPath(import.meta.url));
const source=join(here,'assets/anime-idle-atlas-v1.png');
const out=resolve(process.argv[2]||join(here,'assets/encoded-v1'));
if(existsSync(out))throw Error('Use a new output directory');
mkdirSync(out,{recursive:true,mode:0o700});
const run=(args)=>execFileSync('magick',args,{maxBuffer:16*1024*1024});
const [w,h]=run(['identify','-format','%w %h',source]).toString().split(' ').map(Number);
if(!Number.isInteger(w)||!Number.isInteger(h)||w<768||h<528)throw Error('Unexpected atlas');
const frames=[];
for(let i=0;i<12;i++){
 const c=i%4,r=Math.floor(i/4),x=Math.floor(c*w/4),y=Math.floor(r*h/3);
 const cw=Math.floor((c+1)*w/4)-x,ch=Math.floor((r+1)*h/3)-y;
 const frame=join(out,`frame-${String(i).padStart(2,'0')}.png`);
 run([source,'-crop',`${cw}x${ch}+${x}+${y}`,'+repage','-background','black','-alpha','remove',
      '-alpha','off','-colorspace','Gray','-filter','Lanczos','-resize','192x176!', '-depth','8',frame]);
 const raw=run([frame,'-depth','8','gray:-']);
 if(raw.length!==192*176)throw Error('Bad frame byte count');
 frames.push(raw);
}
const data=Buffer.concat(frames);writeFileSync(join(out,'anime-idle-192x176-l8.bin'),data);
const hash=b=>createHash('sha256').update(b).digest('hex');
const manifest={width:192,height:176,frames:12,format:'L8',frameBytes:33792,totalBytes:data.length,
 sourceWidth:w,sourceHeight:h,sourceSHA256:hash(readFileSync(source)),dataSHA256:hash(data),
 note:'Generated sprite identity/motion consistency requires visual QA. Host preview is not glasses acceptance.'};
writeFileSync(join(out,'manifest.json'),JSON.stringify(manifest,null,2)+'\n');
const pngs=Array.from({length:12},(_,i)=>join(out,`frame-${String(i).padStart(2,'0')}.png`));
run(['-delay','12','-loop','0',...pngs,join(out,'preview-approx-8fps.gif')]);
console.log(JSON.stringify({out,...manifest},null,2));
