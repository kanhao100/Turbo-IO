"""Execute patched ARM hook paths in Unicorn with MOCK native services.
No real PNG decoder, LVGL display, MPU, boot or device validation is claimed.
"""
from pathlib import Path
import argparse,struct,subprocess,json,hashlib
from unicorn import Uc,UC_ARCH_ARM,UC_MODE_THUMB,UC_MODE_MCLASS,UC_HOOK_CODE
from unicorn.arm_const import *
P=argparse.ArgumentParser();P.add_argument('candidate',type=Path)
P.add_argument('--report',default='arm-emulation.json');A=P.parse_args();D=A.candidate
assert Path(A.report).name==A.report
symbols={}
for line in subprocess.check_output(['llvm-nm','--defined-only','--format=posix',str(D/'generated/menu8-experiment.elf')],text=True).splitlines():
    p=line.split()
    if len(p)>=3:symbols[p[0]]=int(p[2],16)
ap=(D/'payload/nuttx_ap.bin').read_bytes()
APP=0x20010000;VM=0x20001000;ROOT=0x20002000;SP=0x200f0000;STOP=0x10000100
REG=[UC_ARM_REG_R0,UC_ARM_REG_R1,UC_ARM_REG_R2,UC_ARM_REG_R3]
def scenario(fail_decode=False):
    u=Uc(UC_ARCH_ARM,UC_MODE_THUMB|UC_MODE_MCLASS)
    u.mem_map(0x10000000,0x1000000);u.mem_write(0x10190000,ap)
    u.mem_map(0x20000000,0x100000);u.mem_map(0x18000000,0x400000)
    # Only non-code literals copied from the stock segment map (not boot simulation).
    # Use the checkout's pinned symbol mapping independent of candidate directory depth.
    base=Path(__file__).resolve().parents[1]/'metadata/symbols.json'
    for lo,hi,at in json.loads(base.read_text())['segments']:
        if 0x18000000<=lo<0x18400000:u.mem_write(lo,ap[at:at+hi-lo])
    def read(p):return struct.unpack('<I',u.mem_read(p,4))[0]
    def write(p,n):u.mem_write(p,struct.pack('<I',n))
    def r(n):return u.reg_read(REG[n])
    def ret(n=0):u.reg_write(UC_ARM_REG_R0,n);u.reg_write(UC_ARM_REG_PC,u.reg_read(UC_ARM_REG_LR))
    write(VM,ROOT);u.mem_write(APP+0xfc,b'GUARD123')
    objects={ROOT:{'source':0,'parent':0,'hidden':False}};next_obj=[0x20020000]
    events=[];malloc_sizes=[];closed=[];native_calls=[]
    calls={v&~1:k for k,v in symbols.items() if k.startswith(('native_','tio_lv_'))}
    # Duplicate aliases for align etc have identical semantics whichever name wins.
    calls[0x107d6128]='malloc';calls[0x107994dc]='ctor';calls[0x1079a8e8]='init'
    resumes={0x1079a788:(12,[UC_ARM_REG_R4,UC_ARM_REG_R7,UC_ARM_REG_PC],'show'),
      0x1079a7bc:(8,[UC_ARM_REG_R4,UC_ARM_REG_R5,UC_ARM_REG_R7,UC_ARM_REG_PC],'hide'),
      0x10799664:(0,[UC_ARM_REG_R4,UC_ARM_REG_R5,UC_ARM_REG_R6,UC_ARM_REG_R7,UC_ARM_REG_PC],'destroy'),
      0x1079a316:(0,[UC_ARM_REG_R4,UC_ARM_REG_R5,UC_ARM_REG_R7,UC_ARM_REG_PC],'wheel'),
      0x1079a894:(8,[UC_ARM_REG_R4,UC_ARM_REG_R5,UC_ARM_REG_R7,UC_ARM_REG_PC],'event')}
    def hook(uc,address,size,unused):
        if address==STOP:u.emu_stop();return
        if address in resumes:
            local,regs,name=resumes[address];native_calls.append('stock_'+name)
            if name=='show':u.mem_write(APP+0x94,b'\1')
            if name=='hide':u.mem_write(APP+0x94,b'\0')
            stack=u.reg_read(UC_ARM_REG_SP)+local
            values=[read(stack+4*i) for i in range(len(regs))]
            u.reg_write(UC_ARM_REG_SP,stack+4*len(regs));u.reg_write(UC_ARM_REG_R0,0)
            for reg,v in zip(regs,values):u.reg_write(reg,v)
            return
        name=calls.get(address)
        if not name:return
        native_calls.append(name)
        if name=='malloc':malloc_sizes.append(r(0));assert r(0)==252;ret(APP)
        elif name=='ctor':u.mem_write(APP,bytes(220));ret(APP)
        elif name=='init':write(APP+4,ROOT);write(APP+8,ROOT+0x100);write(APP+0x88,6);ret()
        elif name=='native_log':
            stack=u.reg_read(UC_ARM_REG_SP);events.append([read(stack+4),read(stack+8)]);ret()
        elif name=='native_settled':ret(1)
        elif name=='native_wake_overlay':ret(0)
        elif name=='native_adjusted_delta':ret(r(1))
        elif name=='native_has_flag':ret(int(objects[r(0)]['hidden']))
        elif name=='native_event_code':ret(0xe)
        elif name=='native_event_key':ret(0x3a)
        elif name in ('tio_lv_obj_create_ex','tio_lv_image_create_ex','native_label_create'):
            p=next_obj[0];next_obj[0]+=0x100;objects[p]={'source':0,'parent':r(0),'hidden':False};ret(p)
        elif name=='tio_lv_obj_delete':
            p=r(0);assert p!=ROOT and p in objects
            children=[k for k,v in objects.items() if v['parent']==p]
            for k in children:del objects[k]
            del objects[p];ret()
        elif name=='tio_lv_obj_add_flag':objects[r(0)]['hidden']=True;ret()
        elif name=='tio_lv_obj_remove_flag':
            if r(1)==1:objects[r(0)]['hidden']=False
            ret()
        elif name=='tio_lv_obj_get_width':ret(540)
        elif name=='tio_lv_obj_get_height':ret(280)
        elif name=='tio_lv_image_decoder_open':
            desc=r(1);blob=bytes(u.mem_read(read(desc+16),read(desc+12)))
            assert hashlib.sha256(blob).hexdigest()=='738169867ec0ca778cd6ce14e803aaa508bf16f8e169d1081db3e622d571db24'
            if fail_decode:ret(0);return
            d=r(0);u.mem_write(d,bytes(76));write(d,0x20040000);write(d+0x2c,0x20050000)
            write(0x20040010,0x20040040);u.mem_write(0x20040040,b'LODEPNG\0')
            u.mem_write(d+0x21,b'\x10');u.mem_write(d+0x24,struct.pack('<HH',88,98));ret(1)
        elif name=='tio_lv_image_decoder_close':closed.append(r(0));ret()
        elif name=='tio_lv_image_set_src':objects[r(0)]['source']=r(1);ret()
        elif name=='tio_lv_image_get_src':ret(objects[r(0)]['source'])
        else:ret()
    u.hook_add(UC_HOOK_CODE,hook)
    def call(addr,*args):
        u.reg_write(UC_ARM_REG_SP,SP);u.reg_write(UC_ARM_REG_LR,STOP|1)
        for i,v in enumerate(args):u.reg_write(REG[i],v&0xffffffff)
        u.emu_start(addr|1,STOP,count=200000)
        assert u.reg_read(UC_ARM_REG_PC)==STOP,'Instruction budget or unexpected stop'
        assert u.reg_read(UC_ARM_REG_SP)==SP,'Unbalanced trampoline stack'
        assert bytes(u.mem_read(APP+0xfc,8))==b'GUARD123','Tail overflow'
    call(0x1079fe04,VM);assert read(VM+0x10)==APP and malloc_sizes==[252]
    call(0x1079a784,APP)
    for index in range(7):
        write(APP+0x88,index)
        before=native_calls.count('stock_event')
        call(0x1079a890,APP,0x20060000)
        assert native_calls.count('stock_event')==before+1,'Stock click intercepted'
        if index<6:
            before=native_calls.count('stock_wheel')
            call(0x1079a310,APP,3)
            assert native_calls.count('stock_wheel')==before+1,'Stock wheel intercepted'
    # Verify original seven-slot memory remains unchanged across extension use.
    stock=bytes(u.mem_read(APP,220))
    call(0x1079a310,APP,3);assert read(APP+0xe0)==2,'Expected tile'
    call(0x1079a890,APP,0x20060000)
    assert read(APP+0xe0)==(0 if fail_decode else 4),'Expected photo or failure rollback'
    assert bytes(u.mem_read(APP,220))==stock,'Stock field overwritten'
    if not fail_decode:
        assert len(closed)==1
        call(0x1079a310,APP,-3);assert read(APP+0xe0)==0
    call(0x1079a7b8,APP);call(0x10799660,APP)
    assert set(objects)=={ROOT},'Leaked native mock objects'
    return dict(decodeFailure=fail_decode,events=events,tailCanary=True,stockPreserved=True,
                stackBalanced=True,nativeCalls=len(native_calls),nativeServices='MOCKS')
result={'kind':'ARM patched-hook emulation only','bootValidated':False,'realPNGDecode':False,
        'deviceIO':False,'scenarios':[scenario(False),scenario(True)]}
out=D/A.report
with out.open('x') as f:json.dump(result,f,indent=2)
out.chmod(0o600);print(json.dumps(result))
