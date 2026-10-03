"""TLC1: isolated extension-only LifeLog eligibility derivative of exact TGR1.

No device I/O. Never patch LauncherAPI itself or the brightness/head-up path.
Relocate its audited idle predicate, eliding only the LifeLog-enabled test,
and retarget six extension home predicates. Diagnostics keep the stock gate.
"""
import argparse, hashlib, json, re, struct, subprocess, zipfile, shutil
from pathlib import Path
from capstone import Cs, CS_ARCH_ARM, CS_MODE_THUMB, CS_MODE_MCLASS

HERE = Path(__file__).resolve().parent
BASE = 0x10190000
START, END, LIFE_CALL = 0x106d334c, 0x106d33f6, 0x106d336e
# Explicit allow-list, established from the original linked ELF (not a raw-byte search).
SITES = {0x10a9cf2c:'navigation', 0x10a9ebc2:'music', 0x10aa2302:'reader',
         0x10aa3f0a:'focus', 0x10aa659e:'ride', 0x10aaaecc:'app-runtime'}
DIAGNOSTICS = {0x10aa00a4, 0x10a9ff34, 0x10a9ff7e}
# Extracted from the original linked TGR1 ELF; valid only for the pinned AP.
HOMES = {'navigation':0x10a9cee6, 'music':0x10a9eb74, 'reader':0x10aa22b6,
         'focus':0x10aa3ecc, 'ride':0x10aa655e, 'app-runtime':0x10aaae94}
def sha(b): return hashlib.sha256(b).hexdigest()
def run(*args): return subprocess.check_output([str(x) for x in args], text=True)
def branch(site,target,link=False):
    delta=(target&~1)-(site+4)
    assert delta%2==0 and -(1<<24)<=delta<(1<<24)
    v=delta&0x1ffffff; s,i1,i2=(v>>24)&1,(v>>23)&1,(v>>22)&1
    return struct.pack('<HH',0xf000|(s<<10)|((v>>12)&0x3ff),
        (0xd000 if link else 0x9000)|((1^i1^s)<<13)|((1^i2^s)<<11)|((v>>1)&0x7ff))

def build(out, SOURCE, STOCK, TOOL):
    assert not out.exists(), 'Never overwrite an artifact'
    assert sha(SOURCE.read_bytes())=='79e56482f4b3688d527ac2ef9c43d7157e6e0767a2d9625aeefe58033808c2ac'
    with zipfile.ZipFile(SOURCE) as z:
        assert z.testzip() is None and len(z.infolist())==15
        infos=z.infolist(); members={i.filename:z.read(i) for i in infos}
    before=members['nuttx_ap.bin']; stock=(STOCK/'nuttx_ap.bin').read_bytes()
    assert len(before)==9593544 and sha(before)=='456929643c3e1bba56d5e4bccaceb62c7290fd3f7f3193161dc043b2bc01e528'
    assert sha(stock)=='53afdf5298815849eafca6f315a70606d2a605aff2e563f79050f797d615a988'
    assert before[START-BASE:END-BASE]==stock[START-BASE:END-BASE]
    assert before[-8:]==stock[-8:]==bytes.fromhex('1d3457be00001930')
    md=Cs(CS_ARCH_ARM,CS_MODE_THUMB|CS_MODE_MCLASS)
    found={}
    for at in set(SITES)|DIAGNOSTICS:
        instructions=list(md.disasm(before[at-BASE:at-BASE+4],at))
        assert len(instructions)==1
        i=instructions[0]
        assert i.mnemonic in ('bl','b.w') and i.op_str==f'#{START:#x}'
        if at in SITES: assert i.mnemonic=='b.w'
        found[at]=('home',i.mnemonic,bytes(i.bytes))
    offset=(len(before)-8+31)&~31; va=BASE+offset
    assembly=['.syntax unified','.cpu cortex-m33','.thumb','.section .text.tlc,"ax",%progbits',
              '.global tlc_display_idle','.type tlc_display_idle,%function','.thumb_func','tlc_display_idle:']
    imports={}; relocation=[]
    for i in md.disasm(before[START-BASE:END-BASE],START):
        assembly.append(f'L_{i.address:x}:')
        op=i.op_str
        if i.address==LIFE_CALL:
            assert i.mnemonic=='bl' and op=='#0x106d308c'
            assembly+=['movs r0, #0','nop']
        elif i.mnemonic in ('bl','b','b.w','beq','bne','cbz','cbnz'):
            m=re.search(r'#(0x[0-9a-f]+)$',op); assert m,(i.mnemonic,op)
            dest=int(m[1],16)
            if START<=dest<END: label=f'L_{dest:x}'
            else: label=f'ext_{dest:x}'; imports[label]=dest|1
            assembly.append(i.mnemonic+' '+op[:m.start()]+label)
            relocation.append(dict(at=i.address,kind='branch',target=dest))
        elif '[pc,' in op:
            m=re.fullmatch(r'(\w+), \[pc, #(0x[0-9a-f]+|\d+)\]',op); assert m
            at=((i.address+4)&~3)+int(m[2],0); value=struct.unpack_from('<I',before,at-BASE)[0]
            assembly.append(f'ldr {m[1]}, ={value:#x}')
            relocation.append(dict(at=i.address,kind='literal',value=value))
        else:
            assert 'pc' not in op or i.mnemonic=='pop', (i.mnemonic,op)
            assembly.append(i.mnemonic+' '+op)
    assembly+=['.size tlc_display_idle, .-tlc_display_idle','.ltorg']
    out.mkdir(parents=True); gen=out/'generated'; gen.mkdir()
    (gen/'coexist.S').write_text('\n'.join(assembly)+'\n')
    (gen/'coexist.ld').write_text('\n'.join(f'{k} = {v:#x};' for k,v in imports.items())+f'''
SECTIONS {{ . = {va:#x}; .text : {{ *(.text*) *(.rodata*) }}
 .data : {{ *(.data*) }} .bss : {{ *(.bss*) *(COMMON) }}
 ASSERT(SIZEOF(.data)==0, "No data") ASSERT(SIZEOF(.bss)==0, "No bss")
 /DISCARD/ : {{ *(.ARM.exidx*) *(.ARM.extab*) *(.comment*) }} }}
''')
    run(TOOL/'clang','--target=arm-none-eabi','-mcpu=cortex-m33','-mthumb','-mfloat-abi=hard','-mfpu=fpv5-sp-d16','-c',gen/'coexist.S','-o',gen/'coexist.o')
    run(TOOL/'ld.lld','-e','tlc_display_idle','-T',gen/'coexist.ld',gen/'coexist.o','-o',gen/'coexist.elf')
    assert not run(TOOL/'llvm-nm','--undefined-only',gen/'coexist.elf').strip()
    run(TOOL/'llvm-objcopy','-O','binary',gen/'coexist.elf',gen/'coexist.bin')
    blob=(gen/'coexist.bin').read_bytes()
    after=bytearray(before[:-8]); after+=bytes(offset-len(after))+blob
    after+=bytes((-len(after))%8)+before[-8:]; patches=[]
    for at,name in SITES.items():
        new=branch(at,va); after[at-BASE:at-BASE+4]=new
        patches.append(dict(app=name,address=at,before=found[at][2].hex(),after=new.hex(),target=va))
    allowed={at-BASE+j for at in SITES for j in range(4)}
    assert all(x==y or at in allowed for at,(x,y) in enumerate(zip(before[:-8],after)))
    assert len(after)<=9600000 and after[:0x9072c0]==before[:0x9072c0]
    assert sha(after)=='bb3fee35ac7ff7f5b76295235323249634cdaf582069972d7b89cff4020f855d', 'Toolchain produced a different AP; stop'
    members['nuttx_ap.bin']=bytes(after)
    manifest=json.loads(members['OtaFileInfo.json'])
    for row in manifest:
        if row['Name']=='nuttx_ap.bin': row['Size']=len(after); row['Md5']=hashlib.md5(after).hexdigest()
        else: assert members[row['Name']]==(STOCK/row['Name']).read_bytes()
        assert row['Size']==len(members[row['Name']]) and row['Md5']==hashlib.md5(members[row['Name']]).hexdigest()
    members['OtaFileInfo.json']=(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n').encode()
    payload=out/'payload'; payload.mkdir()
    for name,data in members.items():
        assert Path(name).name==name; (payload/name).write_bytes(data)
    archive=out/'StrixOS-1.0.4.12-TurboLifeLogCoexist-TLC1-CANDIDATE-NOT-APPROVED.zip'
    with zipfile.ZipFile(archive,'x') as z:
        for info in infos:z.writestr(info,members[info.filename])
    report=dict(build='TLC1-01',sourceAP=sha(before),candidateAP=sha(after),apBytes=len(after),
        apMD5=hashlib.md5(after).hexdigest(),growthBytes=len(after)-len(before),apCapBytes=9600000,
        headroomBytes=9600000-len(after),patches=patches,moduleVA=va,moduleBytes=len(blob),
        relocation=relocation,unchangedPayloads=13,diagnosticsUnchanged=True,
        stockCodeUnchanged=True,brightnessHooks=False,newHeapBytes=0,newTimers=0,newThreads=0,
        archive=dict(name=archive.name,sha256=sha(archive.read_bytes()),bytes=archive.stat().st_size),
        builderSHA256=sha(Path(__file__).read_bytes()),flashed=False,hardwareValidated=False)
    (out/'report.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({k:v for k,v in report.items() if k not in ('patches','relocation')},indent=2))

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--out',type=Path,required=True)
    p.add_argument('--tgr1',type=Path,required=True)
    p.add_argument('--stock',type=Path,required=True)
    p.add_argument('--llvm-bin',type=Path,required=True,help='Directory containing clang, ld.lld, llvm-nm, llvm-objcopy')
    a=p.parse_args()
    for name in ('clang','ld.lld','llvm-nm','llvm-objcopy'):
        assert shutil.which(str(a.llvm_bin.resolve()/name)), name
    build(a.out.resolve(),a.tgr1.resolve(),a.stock.resolve(),a.llvm_bin.resolve())
