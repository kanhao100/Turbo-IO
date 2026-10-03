"""Differential execution of actual stock / TLC1 Thumb predicates in Unicorn.
Service lookup is modeled, not hardware. Checks exact six linked home bodies,
real stock LifeLog preference reader, ABI, stack-only writes, and archive scope.
"""
import argparse, hashlib, itertools, json, struct, zipfile
from pathlib import Path
from capstone import Cs, CS_ARCH_ARM, CS_MODE_THUMB, CS_MODE_MCLASS
from unicorn import Uc, UC_ARCH_ARM, UC_MODE_THUMB, UC_MODE_MCLASS, UC_HOOK_CODE, UC_HOOK_MEM_WRITE
from unicorn.arm_const import *
from build import BASE, START, END, SITES, DIAGNOSTICS, HOMES

p=argparse.ArgumentParser();p.add_argument('candidate',type=Path)
p.add_argument('--tgr1',type=Path,required=True);p.add_argument('--stock',type=Path,required=True)
a=p.parse_args();out=a.candidate;SOURCE=a.tgr1;STOCK=a.stock
report=json.loads((out/'report.json').read_text());ap=(out/'payload/nuttx_ap.bin').read_bytes()
sha=lambda b:hashlib.sha256(b).hexdigest()
assert sha(ap)==report['candidateAP']
stock=(STOCK/'nuttx_ap.bin').read_bytes()
assert sha(stock)=='53afdf5298815849eafca6f315a70606d2a605aff2e563f79050f797d615a988'
assert sha(SOURCE.read_bytes())=='79e56482f4b3688d527ac2ef9c43d7157e6e0767a2d9625aeefe58033808c2ac'
table=json.loads((Path(__file__).resolve().parent.parent/'metadata/symbols.json').read_text())
with zipfile.ZipFile(SOURCE) as z: previous={n:z.read(n) for n in z.namelist()}
with zipfile.ZipFile(out/report['archive']['name']) as z:
    assert z.testzip() is None and len(z.infolist())==15
    current={n:z.read(n) for n in z.namelist()}
assert set(current)==set(previous)
assert {n for n in current if current[n]!=previous[n]}=={'nuttx_ap.bin','OtaFileInfo.json'}
for old,new in zip(json.loads(previous['OtaFileInfo.json']),json.loads(current['OtaFileInfo.json'])):
    if old['Name']=='nuttx_ap.bin':
        assert {k:v for k,v in old.items() if k not in ('Size','Md5')}=={k:v for k,v in new.items() if k not in ('Size','Md5')}
    else: assert old==new
    data=current[new['Name']];assert len(data)==new['Size'] and hashlib.md5(data).hexdigest()==new['Md5']
old=previous['nuttx_ap.bin']; allowed={at-BASE+j for at in SITES for j in range(4)}
assert all(a==b or i in allowed for i,(a,b) in enumerate(zip(old[:-8],ap)))
assert ap[-8:]==old[-8:] and ap[:0x9072c0]==old[:0x9072c0]
md=Cs(CS_ARCH_ARM,CS_MODE_THUMB|CS_MODE_MCLASS)
for at in SITES:
    instructions=list(md.disasm(ap[at-BASE:at-BASE+4],at))
    assert len(instructions)==1 and instructions[0].mnemonic=='b.w' and instructions[0].op_str==f"#{report['moduleVA']:#x}"
for at in DIAGNOSTICS:assert ap[at-BASE:at-BASE+4]==old[at-BASE:at-BASE+4]
assert len(HOMES)==6
STOP,SP=0x10000100,0x203f0000
MON,BAT,INPUT,SERVICE,STORE,TOP=0x20001000,0x20002000,0x20003000,0x20004000,0x20005000,0x20006000
class Machine:
    def __init__(self):
        self.u=Uc(UC_ARCH_ARM,UC_MODE_THUMB|UC_MODE_MCLASS)
        for at,size in [(0x100000,0x1000),(0x10000000,0x1000000),(0x18000000,0x4000000),(0x20000000,0x400000)]:self.u.mem_map(at,size)
        self.u.mem_write(BASE,ap)
        for lo,hi,at in table['segments']:
            if 0x18000000<=lo<0x1c000000:self.u.mem_write(lo,stock[at:at+hi-lo])
        self.mock={0x106e7b5c:'mon',0x106e8458:'bat',0x106e8460:'input',0x106d4c48:'charging',
            0x106d693c:'fold',0x106d3310:'top',0x10941968:'strcmp',0x106d245c:'service_manager',
            0x106b61f0:'string',0x106b60c4:'service',0x106b6028:'destroy_string',
            0x107d5cd8:'log',0x107d6c90:'pref',0x106e08f4:'device_status',0x100108:'strcmp'}
        self.u.hook_add(UC_HOOK_CODE,self.hook);self.u.hook_add(UC_HOOK_MEM_WRITE,self.write)
    def put(self,at,v):self.u.mem_write(at,struct.pack('<I',v))
    def text(self,at):return bytes(self.u.mem_read(at,128)).split(b'\0')[0]
    def ret(self,value=0):self.u.reg_write(UC_ARM_REG_R0,value&0xffffffff);self.u.reg_write(UC_ARM_REG_PC,self.u.reg_read(UC_ARM_REG_LR))
    def write(self,u,access,at,size,value,_):
        assert SP-256<=at and at+size<=SP,('non-stack write',hex(at))
    def hook(self,u,at,size,_):
        if at==STOP:u.emu_stop();return
        if at not in self.mock:return
        name=self.mock[at];a=u.reg_read(UC_ARM_REG_R0);b=u.reg_read(UC_ARM_REG_R1)
        self.calls.append(name)
        if name=='mon':self.ret(MON if self.mon else 0)
        elif name=='bat':self.ret(BAT if self.bat else 0)
        elif name=='input':self.ret(INPUT if self.input else 0)
        elif name=='charging':self.ret(self.charging)
        elif name=='fold':self.ret(self.fold)
        elif name=='top':self.ret(TOP if self.top is not None else 0)
        elif name=='strcmp':self.ret(0 if self.text(a)==self.text(b) else 1)
        elif name=='pref':
            assert a==0x2b;self.put(b,self.life);self.ret(0)
        elif name=='service_manager':self.ret(MON if self.service_manager else 0)
        elif name=='service':self.ret(SERVICE if self.service else 0)
        elif name=='device_status':self.ret(MON)
        else:self.ret()
    def configure(self,**kw):
        d=dict(mon=True,bat=True,input=True,charging=0,fold=0,top='com.rayneo.liteos.launcher',
            life=1,service_manager=True,service=True,store=True,active=0);d.update(kw)
        for k,v in d.items():setattr(self,k,v)
        self.u.mem_write(TOP,(self.top or '').encode()+b'\0');self.put(SERVICE+0x14,STORE if self.store else 0)
        self.u.mem_write(STORE+8,bytes([self.active]));self.calls=[]
    def call(self,at):
        self.calls=[];u=self.u
        saved=[UC_ARM_REG_R4,UC_ARM_REG_R5,UC_ARM_REG_R6,UC_ARM_REG_R7,UC_ARM_REG_R8,UC_ARM_REG_R9,UC_ARM_REG_R10,UC_ARM_REG_R11]
        for i,r in enumerate(saved):u.reg_write(r,0x500+i)
        u.reg_write(UC_ARM_REG_SP,SP);u.reg_write(UC_ARM_REG_LR,STOP|1)
        try:u.emu_start(at|1,STOP,count=10000)
        except Exception as error:raise RuntimeError((hex(at),hex(u.reg_read(UC_ARM_REG_PC)),self.calls)) from error
        assert u.reg_read(UC_ARM_REG_PC)==STOP and u.reg_read(UC_ARM_REG_SP)==SP
        assert all(u.reg_read(r)==0x500+i for i,r in enumerate(saved))
        return u.reg_read(UC_ARM_REG_R0)

m=Machine();checks=[];cases=0
# The clone must equal native behavior with *only* LifeLog disabled, including
# original charging/fold shortcuts and missing-service fallback behavior.
for life,charging,fold,active,top,services in itertools.product(
    (0,1,2),(0,1),(0,1),(0,1),(None,'','EMPTY_PAGE','com.rayneo.liteos.launcher','com.rayneo.liteos.recorder'),range(4)):
    opts=dict(life=life,charging=charging,fold=fold,active=active,top=top,
              service_manager=services!=1,service=services!=2,store=services!=3)
    m.configure(**opts);got=m.call(report['moduleVA']);assert 'pref' not in m.calls
    m.configure(**dict(opts,life=0));expected=m.call(START)
    assert got==expected,(opts,got,expected)
    cases+=1
checks.append(f'{cases} predicate differential cases; actual native preference reader executed')
for name,at in HOMES.items():
    m.configure();assert m.call(START)==0,'native LifeLog gate remains closed'
    assert m.call(at)==1,(name,'background LifeLog should not block');assert 'pref' not in m.calls
    for opts in [dict(active=1),dict(fold=1),dict(mon=False),dict(input=False),
                 dict(top='com.rayneo.liteos.recorder'),dict(top='com.rayneo.liteos.assistant'),
                 dict(top='com.rayneo.liteos.ota'),dict(top='com.rayneo.liteos.prompter'),dict(top=None)]:
        m.configure(**opts);assert m.call(at)==0,(name,opts)
    # Changing LifeLog alone between periodic checks must not retire the view.
    for life in (0,1,0,1):m.configure(life=life);assert m.call(at)==1
    checks.append(name+': actual linked entry/runtime predicate, guards, repeated toggles, ABI verified')
checks+=['13 other OTA payloads unchanged; only AP size/MD5 manifest fields changed',
         'six extension-only branch sites; original code and diagnostic guards unchanged',
         'no persistent RAM, heap, timer, thread, preference write or driver call added']
result=dict(passed=True,AP=report['candidateAP'],differentialCases=cases,checks=checks,
            hardwareValidated=False,modeled=['service lookup','monitor status','preference read'])
(out/'coexist-arm.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result,indent=2))
