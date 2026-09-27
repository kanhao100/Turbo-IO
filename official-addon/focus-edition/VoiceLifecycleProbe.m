#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "TodoProtocol.h"
// Bounded metadata-only observation, not a voice controller or audio recorder.
static void (*PriorVoiceEvent)(id,SEL,id);
static void (*PriorFlutterSend)(id,SEL,id,id,id);
static NSString *Path;
static NSUInteger Count;
static void (*PriorStart)(id,SEL),(*PriorEnd)(id,SEL),(*PriorComplete)(id,SEL),(*PriorStop)(id,SEL);
static void (*PriorAsr)(id,SEL,id,BOOL,id);
static void (*PriorNlp)(id,SEL,id);
static void (*PriorVad)(id,SEL,int32_t);
static void (*PriorTts)(id,SEL,int32_t,id);
static void (*PriorEmit)(id,SEL,id,BOOL,id,NSUInteger);
static id Get(id obj,NSString *key){@try{return [obj valueForKey:key];}@catch(NSException *e){return nil;}}
static BOOL Args(Method m,NSArray<NSString *> *types) {
    if(!m||method_getNumberOfArguments(m)!=types.count+2)return NO;
    char *r=method_copyReturnType(m);BOOL ok=r&&r[0]=='v';free(r);
    for(unsigned i=0;i<types.count;i++){char *t=method_copyArgumentType(m,i+2);ok=ok&&t&&[types[i] containsString:[NSString stringWithFormat:@"%c",t[0]]];free(t);}return ok;
}
static BOOL Valid(Method m,unsigned count) {
    if(!m||method_getNumberOfArguments(m)!=count)return NO;
    char *r=method_copyReturnType(m);BOOL ok=r&&r[0]=='v';free(r);
    for(unsigned i=2;i<count;i++){char *t=method_copyArgumentType(m,i);ok=ok&&t&&t[0]=='@';free(t);}return ok;
}
static id Shape(id v,NSUInteger depth) {
    if(depth>5)return @"depth-limit";
    if([v isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *r=[NSMutableDictionary dictionary];NSUInteger count=0;
        for(id k in v){if(![k isKindOfClass:NSString.class]||++count>24)continue;id x=v[k];
            if([@[@"type",@"event",@"eventType",@"name",@"domain",@"intent",@"sub",@"state"] containsObject:k]&&[x isKindOfClass:NSString.class]&&[x length]<=64&&[x rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-"] invertedSet]].location==NSNotFound)r[k]=x;
            else if([@[@"type",@"businessId",@"status",@"code",@"rc",@"state",@"isRunning",@"running",@"isFinish",@"finished",@"hasNextRound",@"offline",@"validCreateIntent",@"hasError"] containsObject:k]&&[x isKindOfClass:NSNumber.class])r[k]=x;
            else r[k]=Shape(x,depth+1);
        }return r;
    }
    if([v isKindOfClass:NSString.class])return @{@"stringChars":@([v length])};
    if([v isKindOfClass:NSData.class])return @{@"dataBytes":@([v length])};
    if([v isKindOfClass:NSArray.class])return @{@"arrayCount":@([v count])};
    return NSStringFromClass([v class])?:@"nil";
}
static void Record(NSString *kind,id object) {
    id shape=Shape(object,0);
    dispatch_async(dispatch_get_main_queue(),^{
        if(Count++>=400&&![kind isEqual:@"restored"])return;
        NSData *bytes=[NSJSONSerialization dataWithJSONObject:@{@"kind":kind,@"time":@([NSDate.date timeIntervalSince1970]),@"shape":shape} options:0 error:nil];
        NSFileHandle *f=[NSFileHandle fileHandleForWritingAtPath:Path];[f seekToEndOfFile];[f writeData:bytes];[f writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];[f closeFile];
    });
}
static void VoiceHook(id self,SEL cmd,id event) {Record(@"voice-event",event);PriorVoiceEvent(self,cmd,event);}
static void StartHook(id self,SEL cmd){Record(@"audio-start",@{});PriorStart(self,cmd);}
static void EndHook(id self,SEL cmd){Record(@"audio-end",@{});PriorEnd(self,cmd);}
static void CompleteHook(id self,SEL cmd){Record(@"official-complete",@{});PriorComplete(self,cmd);}
static void StopHook(id self,SEL cmd){Record(@"explicit-stop",@{});PriorStop(self,cmd);}
static void AsrHook(id self,SEL cmd,id text,BOOL final,id session){Record(@"asr",@{@"isFinish":@(final),@"text":text?:@""});PriorAsr(self,cmd,text,final,session);}
static void VadHook(id self,SEL cmd,int32_t status){Record(@"vad",@{@"status":@(status)});PriorVad(self,cmd,status);}
static void TtsHook(id self,SEL cmd,int32_t status,id session){Record(@"tts",@{@"status":@(status)});PriorTts(self,cmd,status,session);}
static void EmitHook(id self,SEL cmd,id text,BOOL done,id error,NSUInteger generation){Record(@"custom-emit",@{@"finished":@(done),@"hasError":@(error!=nil),@"text":text?:@""});PriorEmit(self,cmd,text,done,error,generation);}
static void NlpHook(id self,SEL cmd,id response){
    NSMutableDictionary *meta=[NSMutableDictionary dictionary];
    for(NSString *k in @[@"domain",@"intent",@"sub",@"finished",@"hasNextRound",@"offline"])meta[k]=Get(response,k)?:NSNull.null;
    if([meta[@"domain"] isEqual:@"task"]){
        id params=Get(Get(response,@"command"),@"params");id task=[params isKindOfClass:NSDictionary.class]?params[@"task"]:nil;
        if([task isKindOfClass:NSString.class]){NSData *b=[task dataUsingEncoding:NSUTF8StringEncoding];task=b.length<=65536?[NSJSONSerialization JSONObjectWithData:b options:0 error:nil]:nil;}
        meta[@"taskFields"]=[task isKindOfClass:NSDictionary.class]?task:@{};
        meta[@"validCreateIntent"]=@(TIOTodoCreateIntent(meta[@"domain"],meta[@"intent"],params)!=nil);
    }
    Record(@"nlp",meta);PriorNlp(self,cmd,response);
}
static void FlutterHook(id self,SEL cmd,NSString *channel,NSData *data,id reply) {
    if([channel isEqual:@"com.rayneo/sdk/rayneonet"]&&data.length<262144) {
        @try {
            Class cls=NSClassFromString(@"FlutterStandardMethodCodec");
            id codec=((id(*)(id,SEL))objc_msgSend)(cls,NSSelectorFromString(@"sharedInstance"));
            id event=((id(*)(id,SEL,id))objc_msgSend)(codec,NSSelectorFromString(@"decodeEnvelope:"),data);
            id message=[event isKindOfClass:NSDictionary.class]?event[@"message"]:nil;
            if([event[@"eventType"] isEqual:@"messageReceived"]&&[message isKindOfClass:NSDictionary.class]&&[message[@"businessId"] integerValue]==13){
                id payload=message[@"payload"];NSData *wire=[payload isKindOfClass:NSData.class]?payload:[payload valueForKey:@"data"];
                NSDictionary *envelope=TIOVoiceControlEnvelope(wire);
                // Only lifecycle control, never audio frames or text payloads.
                if([@[@1,@3,@4,@7,@11,@12] containsObject:envelope[@"type"]])Record(@"glass-control",envelope);
            }
        }@catch(NSException *e){}
    }
    PriorFlutterSend(self,cmd,channel,data,reply);
}
__attribute__((constructor)) static void Start(void) {
    dispatch_async(dispatch_get_main_queue(),^{
        if(![NSBundle.mainBundle.bundleIdentifier isEqual:@"com.rayneo.venus.pub"]||![[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] isEqual:@"67"])return;
        NSString *dir=[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/TurboIOPrivateAddon"];
        [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil];
        Path=[dir stringByAppendingPathComponent:@"voice-lifecycle-v2.jsonl"];
        if(![NSFileManager.defaultManager fileExistsAtPath:Path])[NSFileManager.defaultManager createFileAtPath:Path contents:NSData.data attributes:@{NSFilePosixPermissions:@0600}];
        Method a=class_getInstanceMethod(NSClassFromString(@"rayneo_venus_sdk_plugin.VoiceAssistantFlutterBridge"),NSSelectorFromString(@"sendEvent:"));
        Method b=class_getInstanceMethod(NSClassFromString(@"FlutterEngine"),NSSelectorFromString(@"sendOnChannel:message:binaryReply:"));
        Class listener=NSClassFromString(@"rayneo_venus_sdk_plugin.AiResultListenerBridge");
        Method starts=class_getInstanceMethod(listener,NSSelectorFromString(@"onAudioRecordStart"));
        Method ends=class_getInstanceMethod(listener,NSSelectorFromString(@"onAudioRecordEnd"));
        Method completes=class_getInstanceMethod(listener,NSSelectorFromString(@"onResponseComplete"));
        Method asr=class_getInstanceMethod(listener,NSSelectorFromString(@"onAsrResult:isFinish:sessionId:"));
        Method nlp=class_getInstanceMethod(listener,NSSelectorFromString(@"onNlpResult:"));
        Method vad=class_getInstanceMethod(listener,NSSelectorFromString(@"onVadStatusChange:"));
        Method tts=class_getInstanceMethod(listener,NSSelectorFromString(@"onTtsStatusChange:sessionId:"));
        Method stop=class_getInstanceMethod(NSClassFromString(@"rayneo_venus_sdk_plugin.VoiceAssistantHelper"),NSSelectorFromString(@"stopWorkflow"));
        Method emit=class_getInstanceMethod(NSClassFromString(@"TIOController"),NSSelectorFromString(@"emitText:done:error:generation:"));
        if(!Valid(a,3)||!Valid(b,5)||!Args(starts,@[])||!Args(ends,@[])||!Args(completes,@[])||!Args(asr,@[@"@",@"Bc",@"@"])||!Args(nlp,@[@"@"])||!Args(vad,@[@"i"])||!Args(tts,@[@"i",@"@"])||!Args(stop,@[])||!Args(emit,@[@"@",@"Bc",@"@",@"Q"])) {Record(@"not-installed",@{});return;}
        PriorVoiceEvent=(void *)method_setImplementation(a,(IMP)VoiceHook);
        PriorFlutterSend=(void *)method_setImplementation(b,(IMP)FlutterHook);
        PriorStart=(void *)method_setImplementation(starts,(IMP)StartHook);
        PriorEnd=(void *)method_setImplementation(ends,(IMP)EndHook);
        PriorComplete=(void *)method_setImplementation(completes,(IMP)CompleteHook);
        PriorAsr=(void *)method_setImplementation(asr,(IMP)AsrHook);
        PriorNlp=(void *)method_setImplementation(nlp,(IMP)NlpHook);
        PriorVad=(void *)method_setImplementation(vad,(IMP)VadHook);
        PriorTts=(void *)method_setImplementation(tts,(IMP)TtsHook);
        PriorStop=(void *)method_setImplementation(stop,(IMP)StopHook);
        PriorEmit=(void *)method_setImplementation(emit,(IMP)EmitHook);
        Record(@"installed",@{});
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,600*NSEC_PER_SEC),dispatch_get_main_queue(),^{
            if(method_getImplementation(a)==(IMP)VoiceHook)method_setImplementation(a,(IMP)PriorVoiceEvent);
            if(method_getImplementation(b)==(IMP)FlutterHook)method_setImplementation(b,(IMP)PriorFlutterSend);
            Method ms[]={starts,ends,completes,asr,nlp,vad,tts,stop,emit};
            IMP hooks[]={(IMP)StartHook,(IMP)EndHook,(IMP)CompleteHook,(IMP)AsrHook,(IMP)NlpHook,(IMP)VadHook,(IMP)TtsHook,(IMP)StopHook,(IMP)EmitHook};
            IMP originals[]={(IMP)PriorStart,(IMP)PriorEnd,(IMP)PriorComplete,(IMP)PriorAsr,(IMP)PriorNlp,(IMP)PriorVad,(IMP)PriorTts,(IMP)PriorStop,(IMP)PriorEmit};
            for(unsigned i=0;i<9;i++)if(method_getImplementation(ms[i])==hooks[i])method_setImplementation(ms[i],originals[i]);
            Record(@"restored",@{});
        });
    });
}
