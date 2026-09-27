"""Physical back survives a late window and exits without a responding phone."""
from pathlib import Path
p=Path(__file__).with_name('test_reader_arm.py')
source=p.read_text().split('# Long press reader ->')[0]
exec(compile(source,str(p),'exec'))
put(EVENT,0x3b);call('m8_hook_vm_event',EVENT);tick(100)
assert any('正在返回书架' in s for s in labels.values())
# Repeated delivery from one long press must not double-exit.
call('m8_hook_vm_event',EVENT);assert tokens
# Complete an in-flight old reading response after back: must stay on back UI.
body(bytes(book),3);tick(100)
assert any('正在返回书架' in s for s in labels.values()) and 'four' not in labels.values()
tick(1000);put(EVENT,0x3b);call('m8_hook_vm_event',EVENT);assert not tokens
tick(100);assert not timers and len(objects)==1
call('wr_slot_destroy',reader);put(slot+28,0);call('tn_slot_destroy',slot);tick(100)
assert alloc.keys()==freed
result={'passed':True,'AP':report['candidateAP'],'lateWindowCannotUndoBack':True,'offlineSecondBackExits':True,'repeatKeyDebounced':True,'noHeapLeaks':True,'physicalKeysNeedAcceptance':True}
(d/'reader-back-offline-arm.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
