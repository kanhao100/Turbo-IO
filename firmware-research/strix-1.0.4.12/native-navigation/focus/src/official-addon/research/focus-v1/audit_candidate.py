"""Independent byte whitelist + payload hashes, extended from audited TWR1."""
from pathlib import Path
p=Path(__file__).resolve().parents[1]/'weread-v1/audit_candidate.py'
exec(compile(p.read_text().split('exec(compile(s,')[0],str(p),'exec'))
change('assert len(new)<=0x9f0000','assert len(new)<=9_600_000, "AP exceeds user ceiling: decimal 9.6 MB"\n assert len(new)<=0x9f0000')
change("'TWR1-offline-experimental-candidate'","'TFP1-focus-interaction-experimental-candidate'",2)
change('native-eleven-TDP1-TNV1-TMU1-TWR1','native-twelve-TFP1')
change('menu11-native-arm.json','menu12-real-sync-arm.json')
change("len(menu['scenarios'])==94","len(menu['scenarios'])==120")
change("s['eleventhMenuDistinct']","s['eleventhMenuDistinct'] and s['nativeWheelIndex11'] and s['twelfthMenuDistinct']")
change("'f2ee047a'","'f2ee067a'");change('10.4666667','11.4666667',2)
change("assert len(new)<=0x9f0000","focus=json.loads((folder/'focus-service-arm.json').read_text());assert focus['passed'] and focus['AP']==sha(new) and focus['singletonBytes']<4096 and focus['boundedPeekLease'] and focus['menuDestructionKeepsTimer'] and focus['localLongStopWithoutPhone']\n quad=json.loads((folder/'menu-quad-arm.json').read_text());assert quad['passed'] and quad['AP']==sha(new) and quad['controllerBytes']<=49152 and quad['parentDeletionNoLeak'] and quad['rendererBusyDefersFree'] and quad['repeatedCreateHideShowDestroyCycles']>=20\n assert len(new)<=0x9f0000")
change("quad['parentDeletionNoLeak']","quad['parentDeletionNoLeak'] and quad['singleControllerIncludingRetirees'] and quad['rapidDestroyWithoutTimerCycles']>=20")
change("quad['rendererBusyDefersFree']", "quad['rendererBusyDefersFree'] and quad['deleteListenerFailureNoOrphan']")
exec(compile(s,str(base),'exec'),{'__file__':str(base),'__name__':'__main__'})
