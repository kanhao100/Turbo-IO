"""Real linked quad-menu/view code with mocked OS/LVGL. Never flashes hardware."""
from pathlib import Path
source=(Path(__file__).resolve().parents[1]/'navigation-runtime-v1/test_service_arm.py').read_text().split("slot=call('tn_slot_create',APP)")[0]
def edit(old,new):
 global source
 assert source.count(old)==1,(old,source.count(old));source=source.replace(old,new)
edit('objnext=0x20040000','objnext=0x20080000')
edit('heap<0x20300000','heap<0x203c0000')
edit("if 'focus_screen_on' in symbols:","for n in ['fm_system','fm_local_time','fm_battery_monitor','fm_battery_level','menu_text_align']:mocks[symbols[n]&~1]=n\nif 'focus_screen_on' in symbols:")
edit("elif n=='focus_screen_on':ret(True)","elif n=='focus_screen_on':ret(screen)\n elif n=='stream_timer_period':assert r(1) in (100,1000);ret()\n elif n=='menu_text_align':assert r(1)==2;ret()")
edit("elif n=='stream_canvas_set_buffer':assert r(2)==r(3)==128;", "elif n=='stream_canvas_set_buffer':\n  assert (r(2),r(3)) in [(64,64),(124,122)]\n  assert any(k not in freed and k<=r(1) and r(1)+r(2)*r(3)<=k+size for k,size in alloc.items())\n  ")
edit("elif n=='menu_font':", "elif n=='native_align':objects[r(0)]['xy']=(r(2),r(3));ret()\n elif n=='tio_lv_obj_set_size':objects[r(0)]['wh']=(r(1),r(2));ret()\n elif n=='menu_font':")
edit("elif n=='stream_memalign':", "elif n in ('fm_system','fm_battery_monitor'):ret(0x20008000 if telemetry else 0)\n elif n=='fm_local_time':u.reg_write(UC_ARM_REG_R1,0);ret(1704067200+9*3600+41*60)\n elif n=='fm_battery_level':ret(75)\n elif n=='native_has_flag':ret(objects.get(r(0),{}).get('hidden',False))\n elif n=='tio_lv_obj_add_flag':\n  if r(1)==1:objects[r(0)]['hidden']=True\n  ret()\n elif n=='tio_lv_obj_remove_flag':\n  if r(1)==1:objects[r(0)]['hidden']=False\n  ret()\n elif n=='stream_memalign':")
edit("assert r(0) in objects;v=objnext;", "assert r(0) in objects\n  if fail_object and len(objects)==fail_object:ret();return\n  v=objnext;")
edit("elif n=='stream_add_event':objects", "elif n=='stream_add_event':\n  if fail_event:ret();return\n  objects")
exec(compile(source,__file__,'exec'))
telemetry=True;fail_object=0;screen=True;fail_event=False
slot=call('tn_slot_create',APP);put(APP+0xdc+28,slot)
DOTS=0x20003500;objects[DOTS]={'parent':PARENT};put(APP+0x60,DOTS)
def menu_root():return next(k for k,v in objects.items() if 'cb' in v)
call('fm_show',APP);assert len(timers)==1 and len(objects)==14
controller_bytes=alloc[word(slot+44)];assert controller_bytes<=49152
APP2=APP+0x400;put(APP2+4,PARENT);slot2=call('tn_slot_create',APP2);put(APP2+0xdc+28,slot2);call('fm_show',APP2);assert not word(slot2+44) and len(timers)==1;call('tn_slot_destroy',slot2);put(APP2+0xdc+28,0)
rootobj=menu_root();assert not objects[rootobj]['hidden'] and objects[DOTS]['hidden']
assert '09:41   75%' in labels.values() and '1/3' in labels.values()
for obj in objects.values():
 if 'xy' in obj and 'wh' in obj:
  x,y=obj['xy'];w,h=obj['wh'];assert 0<=x and 0<=y and x+w<=540 and y+h<=180
LEGACY=0x20003400;objects[LEGACY]={'parent':PARENT};put(APP+8,LEGACY);call('fm_sync',APP);assert objects[LEGACY]['hidden'];put(APP+8,0);objects.pop(LEGACY)
for index in range(12):
 put(APP+0x88,index);call('fm_sync',APP);assert f'{index//4+1}/3' in labels.values()
assert '番茄时钟' in labels.values() and '网易云音乐' in labels.values()
# Test-display pointer is enough to gate all menu decoration off.
put(APP+0xdc+16,1);call('fm_sync',APP);assert objects[rootobj]['hidden'] and objects[DOTS]['hidden'];put(APP+0xdc+16,0)
call('fm_sync',APP);assert not objects[rootobj]['hidden'] and word(APP+0x88)==11
call('fm_hide',APP);tick(1000);assert objects[rootobj]['hidden'];call('fm_show',APP);assert not objects[rootobj]['hidden']
telemetry=False;tick(1100);assert '--:--   --%' in labels.values()
screen=False;before=bytes(u.mem_read(word(slot+44),controller_bytes));tick(2000);assert before==bytes(u.mem_read(word(slot+44),controller_bytes));screen=True
put(0x18001000+24,1);before=bytes(u.mem_read(word(slot+44),controller_bytes));put(APP+0x88,0);call('fm_sync',APP);assert before==bytes(u.mem_read(word(slot+44),controller_bytes));put(0x18001000+24,0)
# Busy renderer retains the view buffers until safe, never frees on detach.
put(0x18001000+24,1);call('fm_destroy',APP);tick(100);assert timers and len(objects)==14
put(0x18001000+24,0);tick(100);assert not timers and len(objects)==2
# A retired controller must be collected before another one is allocated.
call('fm_show',APP);put(0x18001000+24,1);call('fm_destroy',APP);call('fm_show',APP);assert not word(slot+44) and len(timers)==1
put(0x18001000+24,0);call('fm_show',APP);assert word(slot+44) and len(timers)==1 and len(objects)==14;call('fm_destroy',APP);assert not timers
# Parent-driven deletion callback and delayed ownership release.
call('fm_show',APP);rootobj=menu_root();call(objects[rootobj]['cb'],rootobj);assert word(slot+44)==0
objects={PARENT:{},DOTS:{'parent':PARENT}};labels={};tick(100);assert not timers
# Fail at every native child allocation. Fall back without leaked controllers.
for fail_object in range(2,14):
 call('fm_show',APP);assert not timers and len(objects)==2 and word(slot+44)==0
fail_object=0;fail_alloc=True;call('fm_show',APP);assert not timers;fail_alloc=False
# A failed delete-listener allocation must not leave an untracked root/timer.
fail_event=True;call('fm_show',APP);assert not timers and len(objects)==2 and word(slot+44)==0;fail_event=False
call('fm_show',APP);call('fm_destroy',APP);tick(100)
for i in range(20):
 put(APP+0x88,i%12);call('fm_show',APP);call('fm_hide',APP);call('fm_show',APP);call('fm_destroy',APP);tick(100);assert len(objects)==2 and not timers
# Idle rapid teardown must reclaim immediately, without relying on a later tick.
for i in range(20):
 call('fm_show',APP);call('fm_destroy',APP);assert not timers and len(objects)==2
call('tn_slot_destroy',slot);assert not timers and len(freed)==len(alloc)
result={'passed':True,'AP':report['candidateAP'],'syntheticOnly':True,'slots':12,'cardsPerPage':4,'controllerBytes':controller_bytes,'extraLVGLObjects':12,'repeatedCreateHideShowDestroyCycles':20,'rapidDestroyWithoutTimerCycles':20,'singleControllerIncludingRetirees':True,'realLocalClockBinding':True,'missingTelemetryShowsDashes':True,'detailHidesMenuAndDots':True,'selectionRestored':True,'allocationFailureFallback':True,'rendererBusyDefersFree':True,'parentDeletionNoLeak':True,'physicalVerified':False}
result['deleteListenerFailureNoOrphan']=True
(d/'menu-quad-arm.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
