"""Execute TFP1 candidate machine code, including menu-owned view retirement.
OS power/clock are mocks: physical deep-sleep wake remains an acceptance gate.
"""
from pathlib import Path
source=(Path(__file__).resolve().parents[1]/'navigation-runtime-v1/test_service_arm.py').read_text().split("slot=call('tn_slot_create',APP)")[0]
def edit(a,b):
 global source
 assert source.count(a)==1,(a,source.count(a));source=source.replace(a,b)
edit('(16,18,20,32)','(18,20,22,48)')
edit('assert r(2)==r(3)==128','assert r(2)==r(3)==96')
edit("elif n=='stream_timer_delete':", "elif n=='stream_timer_period':assert r(0) in timers and r(1) in (250,1000);ret()\n elif n=='stream_timer_delete':")
edit("'turbo_nav_v1'","'turbo_focus_v1'") if False else None
source=source.replace("'turbo_nav_v1'","'turbo_focus_v1'")
edit("b[5]<128 and len(b)==6+b[5]","b[5]&128 and len(b)==7+(b[5]&127)+(b[6]<<7)")
edit('json.loads(b[6:])','json.loads(b[7:])')
edit("len(ack)==32 and ack[:5]==b'TNA1\\1' and zlib.crc32(ack[:28])==struct.unpack_from('<I',ack,28)[0]","len(ack)==64 and ack[:5]==b'TFA1\\1' and zlib.crc32(ack[:60])==struct.unpack_from('<I',ack,60)[0]")
edit("elif n=='focus_screen_on':ret(True)","elif n=='focus_screen_on':ret(screen)")
edit('global heap,objnext,timernext,queued,events,forwarded','global heap,objnext,timernext,queued,events,forwarded,screen')
edit("calls.append('wake');ret()","calls.append('wake');screen=True;ret()")
edit("elif n=='nav_set_state':assert r(0)==VM and r(1)==1;put(VM+0x1c,1);calls.append('native_state_1');ret()", "elif n=='nav_set_state':\n  assert r(0)==VM and r(1)==1;put(VM+0x1c,1);calls.append('native_state_1');u.reg_write(UC_ARM_REG_R0,focus);u.reg_write(UC_ARM_REG_PC,symbols['tf_slot_hidden']|1)")
exec(compile(source,__file__,'exec'))
screen=True
slot=call('tn_slot_create',APP);put(APP+0xdc+28,slot)
focus=call('tf_slot_create',APP);put(slot+36,focus)
call('stream_register_shim');callback=word(0x19750d2c+0x18)
def send(op,sid,seq,revision,seconds=0,phase=0,result=0):
 b=bytearray(64);b[:6]=b'TFP1'+bytes([1,op]);struct.pack_into('<IIIII',b,8,sid,seq,revision,seconds,phase);struct.pack_into('<I',b,60,zlib.crc32(b[:60]));u.mem_write(WIRE,bytes(b))
 f=bytearray(336);struct.pack_into('<II',f,0,WIRE,len(b));name=b'turbo-focus.tfp\0';f[8:8+len(name)]=name;f[329]=1;struct.pack_into('<I',f,332,len(b));u.mem_write(FILE,bytes(f));before=queued;call(callback,FILE);assert queued==before+1;u.mem_write(WIRE,bytes(64));call(0x106eba90,0,QUEUE);assert replies[-1][5]==result,(result,replies[-1]);return replies[-1]
send(1,0,1,0);assert len(timers)==1 and len(objects)==1
send(2,10,2,0,60);assert tokens and len(objects)==7
before=calls.count('wake');send(2,10,2,0,60);assert calls.count('wake')==before
tick(3100);assert '● 专注计时中' in labels.values()
tick(7000);assert not tokens,'peek leaked permanent display lease'
screen=False;tick(1000);q=send(1,0,3,0);assert q[6]==1
# Link loss does NOT stop timer or release its state.
linked=False;tick(10000);linked=True;q=send(1,0,4,0);assert q[6]==1 and struct.unpack_from('<I',q,20)[0]<49000
screen=True;tick(250);assert tokens # native head/button screen-on peek
# Hiding/menu replacement must keep time; long press is deliberately NOT hide.
call('tf_slot_hidden',focus);tick(250);assert len(objects)==1 and not tokens
# Destroy native menu while timer is running, then recreate; same timer/state.
call('tf_slot_destroy',focus);put(slot+36,0);call('tn_slot_destroy',slot);put(APP+0xdc+28,0);tick(10000)
assert len(timers)==1 and len(alloc.keys()-freed)==1
slot=call('tn_slot_create',APP);put(APP+0xdc+28,slot);focus=call('tf_slot_create',APP);put(slot+36,focus);put(VM+0x1c,0)
business=False;tick(60000);assert len(objects)==1 and not tokens
business=True;tick(250);assert tokens and '时间到，休息一下。' in labels.values();q=send(1,0,5,0);assert q[6]==3 and struct.unpack_from('<I',q,32)[0]==1
tick(11000);assert not tokens;before=calls.count('wake');tick(5000);assert calls.count('wake')==before,'completion repeated wake'
# Busy draw engine retirement and external destruction cannot free referenced text.
put(0x18001000+24,1);call('tf_slot_hidden',focus);tick(250);assert len(objects)==7
put(0x18001000+24,0);tick(250);assert len(objects)==1
q=send(1,0,6,0);rev=struct.unpack_from('<I',q,16)[0];put(VM+0x1c,0);send(2,11,7,rev,60);tick(500)
# Button alone, with the phone link absent: short pauses/resumes, long stops.
linked=False
put(EVENT,0x3a);call('m8_hook_vm_event',EVENT);tick(1000)
assert replies[-1][6]==2,'local short press must pause'
put(EVENT,0x3a);call('m8_hook_vm_event',EVENT);tick(1000)
assert replies[-1][6]==1,'local short press must resume'
put(EVENT,0x3b);call('m8_hook_vm_event',EVENT);tick(250)
assert replies[-1][6]==4 and len(objects)==1 and not tokens,'local long press must stop and close'
# Release after holding cannot relaunch/restart the stopped timer.
put(EVENT,0x3a);call('m8_hook_vm_event',EVENT);tick(250)
linked=True;q=send(1,0,8,0);assert q[6]==4
before=calls.count('wake');tick(70000);assert calls.count('wake')==before,'stopped timer cannot remind'
rev=struct.unpack_from('<I',q,16)[0];put(VM+0x1c,0);send(2,12,9,rev,10);tick(500)
rootobj=next(k for k,v in objects.items() if 'cb' in v);call(objects[rootobj]['cb'],rootobj);objects={PARENT:{}};tick(250);assert not tokens
call('tf_slot_destroy',focus);put(slot+36,0);call('tn_slot_destroy',slot);put(APP+0xdc+28,0)
assert len(alloc.keys()-freed)==1 and len(timers)==1,'only bounded singleton retained intentionally'
result={'passed':True,'AP':report['candidateAP'],'syntheticOnly':True,'localShortPauseResume':True,'localLongStopWithoutPhone':True,'releaseDoesNotRestart':True,'stoppedTimerDoesNotRemind':True,'menuDestructionKeepsTimer':True,'disconnectKeepsTimer':True,'boundedPeekLease':True,'noRepeatedCompletionWake':True,'busyBusinessDefersReminder':True,'busyRendererDefersDestroy':True,'singletonBytes':alloc[next(iter(alloc.keys()-freed))],'physicalSleepVerified':False}
(d/'focus-service-arm.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
