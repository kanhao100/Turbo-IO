"""Run native-eight candidate ARM code + native wheel math with mocked LVGL/OS.
Never connect to a device; this is not a physical animation/boot test.
"""
import argparse,hashlib,json,struct,subprocess
from pathlib import Path
from unicorn import Uc,UC_ARCH_ARM,UC_MODE_THUMB,UC_MODE_MCLASS,UC_HOOK_CODE
from unicorn.arm_const import *
p=argparse.ArgumentParser();p.add_argument('candidate',type=Path);p.add_argument('--report',default='menu9-native-arm.json');a=p.parse_args()
d=a.candidate;report=json.loads((d/'report.json').read_text())
assert report['menuProfile']=='native-nine-TDP1-and-TNV1'
ap=(d/'payload/nuttx_ap.bin').read_bytes();syms={}
symbol_record=json.loads((Path(__file__).resolve().parents[3]/'firmware-inspection/StrixOS-1.0.4.12/symbols.json').read_text())
for line in subprocess.check_output(['llvm-nm','--defined-only','--format=posix',str(d/'generated/menu8-experiment.elf')],text=True).splitlines():
 s=line.split()
 if len(s)>=3:syms[s[0]]=int(s[2],16)
APP=0x20010000;ROOT=0x20020000;LOTTIE=ROOT+256;SP=0x202f0000;STOP=0x10000100
REG=[UC_ARM_REG_R0,UC_ARM_REG_R1,UC_ARM_REG_R2,UC_ARM_REG_R3]
def scenario(fail_at=None):
 u=Uc(UC_ARCH_ARM,UC_MODE_THUMB|UC_MODE_MCLASS)
 u.mem_map(0x10000000,0x1000000);u.mem_write(0x10190000,ap)
 u.mem_map(0x18000000,0x4000000);u.mem_map(0x20000000,0x300000)
 u.mem_map(0xe000e000,0x2000);u.mem_write(0xe000ed88,struct.pack('<I',0xf00000))
 u.reg_write(UC_ARM_REG_FPEXC,0x40000000)
 def word(at):return struct.unpack('<I',u.mem_read(at,4))[0]
 def write(at,n):u.mem_write(at,struct.pack('<I',n&0xffffffff))
 def fp(at,v):u.mem_write(at,struct.pack('<f',v))
 def readfp(at):return struct.unpack('<f',u.mem_read(at,4))[0]
 def reg(n):return u.reg_read(REG[n])
 def signed(n):return n if n<0x80000000 else n-0x100000000
 def ret(n=0):u.reg_write(UC_ARM_REG_R0,n&0xffffffff);u.reg_write(UC_ARM_REG_PC,u.reg_read(UC_ARM_REG_LR))
 def text(at):
  b=bytearray()
  while len(b)<200:
   v=u.mem_read(at+len(b),1)[0]
   if not v:return b.decode()
   b.append(v)
  raise AssertionError('Bad string')
 objects={ROOT:{'parent':0,'hidden':False},LOTTIE:{'parent':ROOT,'hidden':False}}
 nextobj=[ROOT+512];creations=[0];direction=[1];wake=[False];key=[0x3a];now=[1000];opened=[];launched=[];trace=[];nav=[False];SLOT=0x201e0000
 def create(parent,checked=True):
  assert parent in objects
  if checked:
   creations[0]+=1
   if creations[0]==fail_at:return 0
  obj=nextobj[0];nextobj[0]+=256;objects[obj]={'parent':parent,'hidden':False};return obj
 def delete(obj):
  assert obj in objects,'Double delete'
  for child in list(objects):
   if objects.get(child,{}).get('parent')==obj:delete(child)
  del objects[obj]
 calls={v&~1:k for k,v in syms.items() if k.startswith(('native_','tio_lv_','menu_','stream_'))}
 calls.pop(syms['stream_register_shim']&~1,None)
 calls.pop(syms['native_snap']&~1,None) # Execute genuine stop/reset/snap path.
 for name in ['tn_slot_create','tn_slot_destroy','tn_slot_hidden','tn_slot_visible','tn_slot_open']:calls[syms[name]&~1]=name
 for name in ['stock_ctor','stock_names','stock_dots','stock_delete_dots','stock_lottie','stock_refresh_label',
  'stock_hide','stock_show','stock_destroy','stock_event']:
  calls[syms[name]&~1]=name
 for op in ['open','retire']:
  name=('tdp_native_' if report.get('displayProfile') else 'tio_native_page_')+op
  calls[syms[name]&~1]='tio_native_page_'+op
 # Execute the genuine wheel wrapper, stock wheel body, apply/spring clamp and
 # frame helpers. Only effects/timers are mocked, not selected-index math.
 for address in [0x107995b8,0x107995ec,0x1079a180,0x107995d2,0x10799200,0x1079922c]:calls[address]='no_effect'
 def hook(uc,address,size,data):
  if address==STOP:u.emu_stop();return
  name=calls.get(address)
  if not name:return
  if name=='tn_slot_create':u.mem_write(SLOT,bytes(24));ret(SLOT)
  elif name=='tn_slot_visible':ret(nav[0])
  elif name=='tn_slot_open':nav[0]=fail_at!='navpage';ret(nav[0])
  elif name in ['tn_slot_destroy','tn_slot_hidden']:nav[0]=False;ret()
  elif name=='stock_ctor':u.mem_write(APP,bytes(220));ret(APP)
  elif name=='stock_names':
   for i in range(7):
    row=create(ROOT,False);label=create(row,False);objects[label]['text']='stock-'+str(i)
    write(APP+0xc+i*4,row);write(APP+0x28+i*4,label)
   ret()
  elif name=='stock_delete_dots':
   parent=word(APP+0x60)
   if parent:delete(parent)
   write(APP+0x60,0)
   for i in range(7):write(APP+0x64+i*4,0)
   ret()
  elif name=='stock_dots':
   assert not word(APP+0x60),'Fixture builds once; explicit delete tested separately'
   parent=create(ROOT,False);write(APP+0x60,parent)
   for i in range(7):write(APP+0x64+i*4,create(parent,False))
   ret()
  elif name=='stock_lottie':ret()
  elif name in ['stock_show','stock_hide']:
   objects[ROOT]['hidden']=name=='stock_hide';ret()
  elif name=='stock_destroy':delete(ROOT);ret()
  elif name=='stock_event':
   assert word(APP+0x88)<7,'Eighth click fell into native launch table'
   launched.append(word(APP+0x88));ret(1)
  elif name=='tio_native_page_open':
   if fail_at=='page':ret(0);return
   assert not opened;opened.append(reg(1));write(reg(2),0x201f0000);ret(0x201f0000)
  elif name=='tio_native_page_retire':assert opened;opened.clear();ret()
  elif name in ['tio_lv_obj_create_ex','native_label_create']:ret(create(reg(0)))
  elif name=='tio_lv_obj_delete':delete(reg(0));ret()
  elif name in ['tio_lv_obj_add_flag','tio_lv_obj_remove_flag']:
   assert reg(0) in objects
   if reg(1)==1:objects[reg(0)]['hidden']=name.endswith('add_flag')
   ret()
  elif name=='native_has_flag':ret(int(objects[reg(0)]['hidden']))
  elif name=='native_wake_overlay':ret(int(wake[0]))
  elif name=='native_adjusted_delta':ret(signed(reg(1))*direction[0])
  elif name=='native_event_code':ret(0xe)
  elif name=='native_event_key':ret(key[0])
  elif name=='native_label_text':objects[reg(0)]['text']=text(reg(1));ret()
  elif name=='tio_lv_obj_set_size':objects[reg(0)]['size']=(reg(1),reg(2));ret()
  elif name=='menu_opa':objects[reg(0)]['opa']=reg(1);ret()
  elif name=='tio_lv_obj_set_style_bg_opa':objects[reg(0)]['bg_opa']=reg(1);ret()
  elif name=='menu_translate':objects[reg(0)]['x']=signed(reg(1));ret()
  elif name in ['native_align','tio_lv_obj_align']:objects[reg(0)]['align']=(reg(1),signed(reg(2)),signed(reg(3)));ret()
  elif name=='menu_lottie_frame':assert reg(1)<=195;objects[reg(0)]['frame']=reg(1);ret()
  elif name=='menu_font':ret(0x1234)
  elif name=='stream_tick':now[0]+=1;ret(now[0])
  elif name=='native_log':trace.append(text(word(u.reg_read(UC_ARM_REG_SP))));ret()
  elif name in ['menu_remove_styles','native_text_color','menu_text_align','menu_text_font',
      'tio_lv_obj_set_style_bg_color','native_unregister_wheel','native_report_activity','no_effect','stock_refresh_label']:ret()
  else:raise AssertionError('Unimplemented native mock '+name)
 u.hook_add(UC_HOOK_CODE,hook)
 u.mem_write(APP+252,b'GUARD123')
 def call(addr,*args):
  u.reg_write(UC_ARM_REG_SP,SP);u.reg_write(UC_ARM_REG_LR,STOP|1)
  for i,v in enumerate(args):u.reg_write(REG[i],v&0xffffffff)
  u.emu_start((syms[addr] if isinstance(addr,str) else addr)|1,STOP,count=500000)
  assert u.reg_read(UC_ARM_REG_PC)==STOP,'Unexpected ARM stop'
  assert u.reg_read(UC_ARM_REG_SP)==SP,'Unbalanced stack'
  assert bytes(u.mem_read(APP+252,8))==b'GUARD123','Eighth slot overflow'
  return u.reg_read(UC_ARM_REG_R0)
 call('m8_hook_ctor',APP);write(APP+4,ROOT);write(APP+8,LOTTIE);u.mem_write(APP+0x94,b'\1')
 call(0x10799dec,APP);call(0x107998b8,APP);call(0x10799c58,APP)
 original_arrays=bytes(u.mem_read(APP+0xc,0x54))
 for n in range(-40,280):
  assert call(0x1079911a,n,0x123,0x456,0x789)==15+30*max(0,min(8,n))
  assert [u.reg_read(r) for r in REG[1:]]==[0x123,0x456,0x789],'Leaf helper clobbers native caller registers'
  assert call(0x10799130,n,0x123,0x456,0x789)==max(0,min(269,n))//30
  assert [u.reg_read(r) for r in REG[1:]]==[0x123,0x456,0x789]
 if fail_at is None:
  assert len([o for o in objects.values() if o['parent']==word(APP+0x60)])==9
  assert word(APP+0xdc) and word(APP+0xe4),'Missing eighth row/icon'
 for frame in list(range(270))+list(range(269,-1,-1)):
  call(0x10799d38,APP,frame);call(0x1079a01c,APP,frame)
  if fail_at is None:
   row=word(APP+0xdc);icon=word(APP+0xe4)
   if frame==225:
    assert not objects[row]['hidden'] and objects[row]['opa']==255
    assert not objects[icon]['hidden'] and objects[icon]['opa']==255
    assert objects[LOTTIE]['opa']==0 and objects[word(APP+0xe8)]['size']==(12,4)
   if frame==255:
    assert objects[word(SLOT)]['opa']==255 and not objects[word(SLOT)]['hidden']
    assert objects[word(SLOT+8)]['opa']==255 and not objects[word(SLOT+8)]['hidden']
    assert objects[icon]['hidden'] and objects[LOTTIE]['opa']==0
    assert objects[word(SLOT+12)]['size']==(12,4)
  assert bytes(u.mem_read(APP+0xc,0x54))==original_arrays
 # Genuine raw wheel + native float target: move 6 -> 7, sustain jitter, back.
 wheel_params=word(0x1079a300)
 assert wheel_params==word(0x107992ec)==0x1832f2f8
 defaults=word(0x10799590)
 assert defaults==0x182d6560
 segment=next((lo,hi,off) for lo,hi,off in symbol_record['segments'] if lo<=defaults and defaults+12<=hi)
 at=segment[2]+defaults-segment[0];u.mem_write(wheel_params,ap[at:at+12])
 assert abs(readfp(wheel_params)-0.0017)<1e-8
 def selected(index):
  write(APP+0x88,index);u.mem_write(APP+0xa5,b'\0');fp(APP+0xac,float(index));fp(APP+0xa8,float(index))
 selected(6);call(0x1079a310,APP,600);assert word(APP+0x88)==7,('Native wheel did not reach 7',word(APP+0x88),readfp(APP+0xac),readfp(APP+0xb0))
 for delta in [-1,0,1,0,-1,1]*20:call(0x1079a310,APP,delta);assert word(APP+0x88)==7
 selected(7);call(0x1079a310,APP,-600);assert word(APP+0x88)==6
 selected(6);direction[0]=-1;call(0x1079a310,APP,-600);assert word(APP+0x88)==7;direction[0]=1
 selected(7);call(0x1079a310,APP,600);assert word(APP+0x88)==8
 for delta in [-1,0,1,0,-1,1]*20:call(0x1079a310,APP,delta);assert word(APP+0x88)==8
 selected(8);call(0x1079a310,APP,-600);assert word(APP+0x88)==7
 for start in range(9):
  for delta in [-1000000,-600,-2,2,600,1000000]:
   selected(start);call(0x1079a310,APP,delta);assert word(APP+0x88)<=8
 fp(APP+0xa8,99);call(0x107992f4,APP);assert 8.46<readfp(APP+0xa8)<8.47
 fp(APP+0xa8,7);write(APP+0x90,0);call(0x10799d6e,APP);assert word(APP+0x90)==225
 fp(APP+0xa8,8);write(APP+0x90,0);call(0x10799d6e,APP);assert word(APP+0x90)==255
 for index in range(7):selected(index);call(0x1079a890,APP,0)
 assert launched==list(range(7))
 selected(7);wake[0]=True;call(0x1079a890,APP,0);assert not opened;wake[0]=False
 call(0x1079a890,APP,0);assert len(launched)==7
 if fail_at!='page':
  assert opened
  call(0x1079a310,APP,-80);assert word(APP+0x88)==7
  call(0x1079a890,APP,0);assert len(opened)==1 and len(launched)==7
 call(0x1079a7b8,APP);assert not opened
 call(0x1079a784,APP);assert word(APP+0x88)==7
 selected(8);call(0x1079a890,APP,0);assert nav[0]==(fail_at!='navpage');assert len(launched)==7
 call(0x1079a7b8,APP);assert not nav[0]
 call(0x10799896,APP);assert word(APP+0xe8)==0
 call(0x10799660,APP);assert not objects
 return {'failAt':fail_at,'passed':True,'nativeWheelIndex7':True,'nativeReverseDirection':True,
  'smallDeltaStable':True,'stockWheelDefaults':True,'extremeWheelBounded':True,'stockSevenLaunches':launched,'eighthNeverLaunchesDND':True,
  'frameSweep':540,'nativeWheelIndex8':True,'ninthMenuDistinct':True,'originalArrayPointersPreserved':True,'tailCanary':True,'destroyNoDoubleFree':True}
result={'kind':'Native nine-index ARM offline test','apSHA256':hashlib.sha256(ap).hexdigest(),
 'realWheelMath':True,'nativeUIAndPageAreMocks':True,'deviceIO':False,'displayValidated':False,
 'scenarios':[scenario()]+[scenario(n) for n in range(1,29)]+[scenario('page'),scenario('navpage')]}
assert Path(a.report).name==a.report
with (d/a.report).open('x') as f:json.dump(result,f,indent=2)
print(json.dumps({'passed':True,'scenarios':len(result['scenarios']),'apSHA256':result['apSHA256'],'displayValidated':False}))
