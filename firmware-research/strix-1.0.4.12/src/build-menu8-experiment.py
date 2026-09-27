"""Hash-pinned OFFLINE AP experiment builder. Never flashes or contacts devices.

Output is a NEW untested candidate, not automatically the hardware-tested R3.
The published reference photo is authorized by its owner. No device I/O.
"""
import argparse, hashlib, json, os, shutil, struct, subprocess, zipfile
from pathlib import Path
import capstone

ROOT=Path(__file__).resolve().parents[1]
SRC=ROOT/'src'
AP_SHA='53afdf5298815849eafca6f315a70606d2a605aff2e563f79050f797d615a988'
PNG_SHA='738169867ec0ca778cd6ce14e803aaa508bf16f8e169d1081db3e622d571db24'
BASE=0x10190000
CAPACITY=0x9f0000
HOOKS=[('show',0x1079a784,4),('hide',0x1079a7b8,4),
       ('destroy',0x10799660,4),('wheel',0x1079a310,6),('event',0x1079a890,4)]
ALIASES={
 'stock_ctor':'rayneo::app::launcher::AppListView::AppListView',
 'native_adjusted_delta':'rayneo::app::launcher::AppListView::adjustedRawWheelDelta',
 'native_unregister_wheel':'rayneo::app::launcher::AppListView::unregisterRawWheelListener',
 'native_settled':'rayneo::app::launcher::AppListView::isRawWheelSlideSettled',
 'native_wake_overlay':'rayneo::app::launcher::isLauncherEncoderWakeOverlayVisible',
 'native_report_activity':'lv_rayneo_display_report_activity',
 'native_has_flag':'lv_obj_has_flag','native_event_code':'lv_event_get_code',
 'native_event_key':'lv_event_get_key','native_label_create':'lv_label_create',
 'native_label_text':'lv_label_set_text','native_text_color':'lv_obj_set_style_text_color',
 'native_align':'lv_obj_align','native_log':'logger_log'}
def digest(b,alg='sha256'):return hashlib.new(alg,b).hexdigest()
def run(args,**kw):return subprocess.run([str(x) for x in args],check=True,capture_output=True,**kw).stdout
def put(p,data):
    with p.open('xb') as f:f.write(data.encode() if isinstance(data,str) else data)
    p.chmod(0o600)
def branch(site,target,link=False):
    delta=(target&~1)-(site+4)
    assert delta%2==0 and -(1<<24)<=delta<(1<<24),'Branch out of range'
    bits=delta&0x1ffffff;s=(bits>>24)&1;i1=(bits>>23)&1;i2=(bits>>22)&1
    j1=1^(i1^s);j2=1^(i2^s)
    return struct.pack('<HH',0xf000|(s<<10)|((bits>>12)&0x3ff),
      (0xd000 if link else 0x9000)|(j1<<13)|(j2<<11)|((bits>>1)&0x7ff))

def build(out, firmware, png):
    assert not out.exists(),'Output must be new'
    ap=(firmware/'nuttx_ap.bin').read_bytes();assert digest(ap)==AP_SHA
    assert len(ap)==9466560 and ap[-8:]==bytes.fromhex('1d3457be00001930')
    partition=bytearray(116);partition[:2]=b'ap'
    struct.pack_into('<II',partition,104,0xc80,0x4f80)
    assert ap.find(partition)==0x2d9304,'AP partition descriptor changed'
    assert digest(png.read_bytes())==PNG_SHA
    manifest=json.loads((firmware/'OtaFileInfo.json').read_bytes())
    baseline=json.loads((firmware/'baseline.json').read_bytes())
    assert len(manifest)==14 and len({r['Name'] for r in manifest})==14
    originals={}
    for row in manifest:
        name=row['Name'];assert Path(name).name==name
        b=(firmware/name).read_bytes()
        assert len(b)==row['Size'] and digest(b,'md5')==row['Md5']
        assert digest(b)==next(r['sha256'] for r in baseline['files'] if r['name']==name)
        originals[name]=b
    syms=json.loads((firmware/'symbols.json').read_bytes())
    def locate(addr):
        for low,high,at in syms['segments']:
            if low<=addr<high:return at+addr-low
        assert BASE<=addr<BASE+len(ap)
        return addr-BASE
    def symbol(name):
        matches=[e for e in syms['entries'] if e['name']==name]
        addresses={e['address'] for e in matches}
        assert len(addresses)==1 and next(iter(addresses))&1,name
        for e in matches:
            p,a=struct.unpack_from('<II',ap,e['tableOffset']);assert a==e['address']
            at=locate(p);assert ap[at:at+len(name)+1]==name.encode()+b'\0'
        return next(iter(addresses))
    md=capstone.Cs(capstone.CS_ARCH_ARM,capstone.CS_MODE_THUMB);md.detail=True
    entries=set(syms['entryPoints'])
    for name,addr,n in HOOKS:
        instructions=list(md.disasm(ap[addr-BASE:addr-BASE+n],addr))
        assert sum(i.size for i in instructions)==n
        assert not any(addr<e<addr+n for e in entries)
        for i in instructions:
            assert i.mnemonic in ('push','push.w','sub','mov','ldr.w','ldrb.w'),(name,i.mnemonic)
            assert 'pc' not in i.op_str and not i.mnemonic.startswith('b')
    assert ap[0x1079fe2c-BASE:0x1079fe2e-BASE]==bytes.fromhex('dc20')
    ctor_instruction=next(md.disasm(ap[0x1079fe3c-BASE:0x1079fe40-BASE],0x1079fe3c))
    assert ctor_instruction.mnemonic=='bl' and ctor_instruction.operands[0].imm==0x107994dc
    out.mkdir(parents=True,mode=0o700)
    generated=out/'generated'
    run(['node',SRC/'prepare-menu8-linkcheck.mjs',firmware,png,generated])
    assignments=(generated/'native-symbols.ld').read_text()
    resolved=[]
    for alias,name in ALIASES.items():
        addr=symbol(name);assignments+=f'{alias} = 0x{addr:x};\n'
        resolved.append(dict(alias=alias,name=name,address=hex(addr)))
    assembly='.syntax unified\n.cpu cortex-m55\n.thumb\n.section .text.trampolines,"ax",%progbits\n'
    for name,addr,n in HOOKS:
        assembly+=f'.balign 2\n.global stock_{name}\n.type stock_{name},%function\n.thumb_func\nstock_{name}:\n'
        assembly+='.byte '+','.join(hex(x) for x in ap[addr-BASE:addr-BASE+n])+'\n'
        assembly+=f'b.w resume_{name}\n.size stock_{name},.-stock_{name}\n'
        assignments+=f'resume_{name} = 0x{(addr+n)|1:x};\n'
    put(generated/'trampolines.S',assembly)
    # Preserve all original build-info text and its header pointer. Move only
    # the terminal BUILD_INFO_MAGIC/base pair to the new physical end.
    footer_at=len(ap)-8; module_at=(footer_at+31)&~31;module_va=BASE+module_at
    script=assignments+f'''\nSECTIONS {{
      . = 0x{module_va:x};
      __module_start = .;
      .text : {{ *(.text .text.*) }}
      .rodata ALIGN(4) : {{ *(.rodata .rodata.*) }}
      .data : {{ *(.data .data.*) }}
      .bss : {{ *(.bss .bss.* COMMON) }}
      __module_end = .;
      /DISCARD/ : {{ *(.ARM.exidx* .ARM.extab* .comment .note* .llvm_addrsig) }}
    }}
    ASSERT(SIZEOF(.data) == 0, "Unexpected writable data")
    ASSERT(SIZEOF(.bss) == 0, "Unexpected BSS")
    ASSERT(__module_end < 0x{BASE+CAPACITY-8:x}, "AP partition capacity exceeded")
    '''
    put(generated/'link.ld',script)
    compiler=shutil.which('clang');linker=shutil.which('ld.lld');objcopy=shutil.which('llvm-objcopy');nm=shutil.which('llvm-nm')
    assert compiler and linker and objcopy and nm
    # Conservative Armv8-M Mainline subset: no M55 low-overhead loops/MVE in
    # extension code. All native calls here use integer/pointer arguments.
    flags=['--target=arm-none-eabi','-mcpu=cortex-m33','-mthumb','-mfloat-abi=hard','-mfpu=fpv5-sp-d16',
           '-ffreestanding','-fno-builtin','-fno-unwind-tables','-fno-asynchronous-unwind-tables','-Os',
           '-Wall','-Wextra','-Werror','-I',str(SRC)]
    objects=[]
    for source in [SRC/(s+'.c') for s in ['menu8-sidecar','menu8-renderer','menu8-native-lvgl','menu8-owner-layout','menu8-hooks']]+[generated/'photo-payload.c',generated/'trampolines.S']:
        obj=generated/(source.stem+'.o');run([compiler,*flags,'-c',source,'-o',obj]);objects.append(obj)
    elf=generated/'menu8-experiment.elf'
    run([linker,'-T',generated/'link.ld','--entry=m8_hook_ctor',*objects,'-o',elf])
    assert not run([nm,'-u',elf]).strip(),'Unresolved target symbols'
    symbol_map={}
    for line in run([nm,'--defined-only','--format=posix',elf]).decode().splitlines():
        parts=line.split()
        if len(parts)>=3:symbol_map[parts[0]]=int(parts[2],16)
    blobfile=generated/'module.bin';run([objcopy,'-O','binary',elf,blobfile]);blob=blobfile.read_bytes()
    assert symbol_map['__module_start']==module_va
    assert symbol_map['__module_end']-module_va==len(blob)
    patched=bytearray(ap[:footer_at]);patched.extend(b'\0'*(module_at-len(patched)));patched.extend(blob)
    patched.extend(b'\0'*((-len(patched))%4));patched.extend(ap[-8:])
    assert len(patched)<=CAPACITY
    changes=[]
    def replace(at,data,role):
        before=bytes(patched[at:at+len(data)]);patched[at:at+len(data)]=data
        changes.append(dict(offset=hex(at),length=len(data),before=before.hex(),after=data.hex(),role=role))
    replace(0x1079fe2c-BASE,bytes.fromhex('fc20'),'AppList allocation 220 to 252')
    for name,addr,n in HOOKS:
        target=symbol_map['m8_hook_'+name];encoded=branch(addr,target)
        i=next(md.disasm(encoded,addr));assert i.mnemonic=='b.w' and i.operands[0].imm==(target&~1)
        replace(addr-BASE,encoded+bytes.fromhex('00bf')*((n-4)//2),'Entry trampoline '+name)
        trampoline=symbol_map['stock_'+name]&~1
        off=trampoline-module_va
        assert blob[off:off+n]==ap[addr-BASE:addr-BASE+n]
        jump=next(md.disasm(blob[off+n:off+n+4],trampoline+n))
        assert jump.mnemonic=='b.w' and jump.operands[0].imm==addr+n
    target=symbol_map['m8_hook_ctor'];data=branch(0x1079fe3c,target,True)
    i=next(md.disasm(data,0x1079fe3c));assert i.mnemonic=='bl' and i.operands[0].imm==(target&~1)
    replace(0x1079fe3c-BASE,data,'Initialize tail after original constructor')
    allowed=set()
    for r in changes:allowed.update(range(int(r['offset'],16),int(r['offset'],16)+r['length']))
    assert all(ap[i]==patched[i] or i in allowed for i in range(footer_at))
    assert patched[:16]==ap[:16] and patched[-8:]==ap[-8:]
    build_at=struct.unpack_from('<I',ap,12)[0]-0x30190000
    assert bytes(patched[build_at:footer_at])==ap[build_at:footer_at]
    payload=out/'payload';payload.mkdir(mode=0o700)
    audit=[]
    for row in manifest:
        name=row['Name'];b=bytes(patched) if name=='nuttx_ap.bin' else originals[name]
        put(payload/name,b);row['Size']=len(b);row['Md5']=digest(b,'md5')
        audit.append(dict(name=name,bytes=len(b),sha256=digest(b),unchanged=b==originals[name]))
    assert sum(r['unchanged'] for r in audit)==13
    put(payload/'OtaFileInfo.json',json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
    archive=out/'StrixOS-1.0.4.12-TurboPhoto-menu8-EXPERIMENTAL-UNFLASHED.zip'
    with zipfile.ZipFile(archive,'x',compression=zipfile.ZIP_DEFLATED) as z:
        for name in ['OtaFileInfo.json']+list(originals):z.write(payload/name,name)
    archive.chmod(0o600)
    with zipfile.ZipFile(archive) as z:
        assert z.testzip() is None
        assert z.namelist()==['OtaFileInfo.json']+list(originals)
        for name in z.namelist():assert z.read(name)==(payload/name).read_bytes()
    report=dict(kind='menu8-photo-experimental-ota',deviceIO=False,flashed=False,
      originalAP=AP_SHA,candidateAP=digest(patched),candidateAPBytes=len(patched),
      moduleOffset=hex(module_at),moduleVA=hex(module_va),moduleBytes=len(blob),
      extensionISA='Armv8-M Mainline Thumb, Cortex-M33 subset, hard-float ABI',
      apCapacity=hex(CAPACITY),changes=changes,footerRelocated=True,headerUnchanged=True,
      unchangedPayloads=13,payloads=audit,bindings=resolved,
      checks=dict(noUndefinedSymbols=True,trampolineReadback=True,branchTargets=True,
                  diffWhitelist=True,manifest=True,zipReadback=True),
      runtimeValidated=False,productionReady=False,
      unresolved=['MPU/background-map execution at appended address not observed on hardware',
        'Native LVGL ABI/PNG decoder and allocation failure behavior not executed on glasses',
        'Raw wheel callback/UI thread serialization must be confirmed',
        'Same-version OTA acceptance, changed-AP boot and recovery are unverified',
        'Moving terminal build-info marker matches reference SDK layout, target installer/boot not executed'],
      archive=dict(name=archive.name,bytes=archive.stat().st_size,sha256=digest(archive.read_bytes())))
    put(out/'report.json',json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps({k:report[k] for k in ['candidateAP','candidateAPBytes','moduleVA','moduleBytes','unchangedPayloads','archive','unresolved']}))
    return report
if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('output',type=Path)
    p.add_argument('--baseline',type=Path,default=ROOT/'work/baseline')
    p.add_argument('--photo',type=Path,default=ROOT/'assets/turbo-photo-firmware.png')
    a=p.parse_args()
    build(a.output.resolve(),a.baseline.resolve(),a.photo.resolve())
