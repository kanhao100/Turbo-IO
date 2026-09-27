#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "TodoProtocol.h"

// Private, bounded runtime schema probe. It never sends a Bluetooth message,
// invokes a task action, collects audio, or records arbitrary task text/IDs.
static NSString *ProbePath;
static NSUInteger ProbeCount;
static void (*OriginalMethod)(id,SEL,id,id);
static void (*OriginalSend)(id,SEL,id,id,id);
static NSUInteger SchemaSamples;
static NSUInteger EventSamples;
static void (*OriginalNlpProbe)(id,SEL,id);
static NSDictionary *Envelope(NSData *data) {
    if(![data isKindOfClass:NSData.class]||data.length>65536)return nil;
    const uint8_t *p=data.bytes;NSUInteger i=0,n=data.length;uint64_t type=0,version=0;NSData *json=nil;
    NSMutableSet *seen=[NSMutableSet set];
    while(i<n){
        uint64_t values[2]={0,0};
        for(int k=0;k<2;k++){BOOL end=NO;for(unsigned shift=0;shift<63&&i<n;shift+=7){uint8_t b=p[i++];values[k]|=((uint64_t)(b&127)<<shift);if(!(b&128)){end=YES;break;}}if(!end)return nil;}
        uint64_t key=values[0],value=values[1],tag=key>>3,wire=key&7;
        if([seen containsObject:@(tag)])return nil;[seen addObject:@(tag)];
        if(wire==0){if(tag==1)version=value;if(tag==2)type=value;}
        else if(wire==2){if(value>n-i)return nil;if(tag==3)json=[data subdataWithRange:NSMakeRange(i,(NSUInteger)value)];i+=(NSUInteger)value;}
        else return nil;
    }
    if(version!=1||!json)return nil;id object=[NSJSONSerialization JSONObjectWithData:json options:0 error:nil];
    return [object isKindOfClass:NSDictionary.class]?@{@"type":@(type),@"json":object}:nil;
}
static BOOL Signature(Method m,NSUInteger count) {
    if(!m||method_getNumberOfArguments(m)!=count)return NO;
    char *r=method_copyReturnType(m);BOOL ok=r&&r[0]=='v';free(r);
    for(NSUInteger i=2;i<count;i++){char *t=method_copyArgumentType(m,(unsigned)i);ok=ok&&t&&t[0]=='@';free(t);}return ok;
}
static id Getter(id obj,NSString *key) { @try { return [obj valueForKey:key]; } @catch(NSException *e) { return nil; } }
static id Shape(id value,NSUInteger depth) {
    if(depth>7)return @"depth-limit";
    if([value isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *out=[NSMutableDictionary dictionary]; NSUInteger n=0;
        for(id key in value){if(![key isKindOfClass:NSString.class]||++n>30)continue;
            id v=value[key];
            if([@[@"businessId",@"type",@"success",@"status",@"eventType",@"version",@"msgType",@"offline",@"finished",@"hasNextRound",@"parsedCreateIntent"] containsObject:key]&&[v isKindOfClass:NSNumber.class])out[key]=v;
            else if([@[@"eventType",@"commandName",@"sub"] containsObject:key]&&[v isKindOfClass:NSString.class]&&[v length]<=64&&[v rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-"] invertedSet]].location==NSNotFound)out[key]=v;
            else if([key isEqual:@"intent"]&&[v isEqual:@"create_task"])out[key]=v;
            else out[key]=Shape(v,depth+1);
        }return out;
    }
    if([value isKindOfClass:NSArray.class])return @{ @"arrayCount":@([value count]),@"firstShape":[value count]?Shape(value[0],depth+1):@"empty" };
    if([value isKindOfClass:NSData.class])return @{ @"dataBytes":@([value length]) };
    if([NSStringFromClass([value class]) isEqual:@"FlutterStandardTypedData"]){NSDictionary *envelope=Envelope(Getter(value,@"data"));return envelope?Shape(envelope,depth+1):@"unrecognized-typed-data";}
    if([value isKindOfClass:NSString.class])return @{ @"stringChars":@([value length]) };
    return NSStringFromClass([value class])?:@"nil";
}
static void Record(NSString *kind,id value) {
    dispatch_async(dispatch_get_main_queue(),^{
        if(ProbeCount++>=500 && ![kind isEqual:@"probe-restored"])return;
        NSDictionary *row=@{@"kind":kind,@"time":@([NSDate.date timeIntervalSince1970]),@"shape":Shape(value,0)};
        NSData *data=[NSJSONSerialization dataWithJSONObject:row options:0 error:nil];if(!data)return;
        NSFileHandle *f=[NSFileHandle fileHandleForWritingAtPath:ProbePath];[f seekToEndOfFile];[f writeData:data];[f writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];[f closeFile];
    });
}
static void MethodHook(id self,SEL cmd,id call,id result) {
    if([Getter(call,@"method") isEqual:@"rayneonet_sendMessage"]){id args=Getter(call,@"arguments");
        if(SchemaSamples++<3)Record(@"send-argument-schema",args);
        if([args isKindOfClass:NSDictionary.class]&&[args[@"businessId"] integerValue]==22)Record(@"outbound-todo",args);
    }
    OriginalMethod(self,cmd,call,result);
}
static void NlpProbe(id self,SEL cmd,id response) {
    if([Getter(response,@"domain") isEqual:@"task"]){
        id command=Getter(response,@"command");
        if([command isKindOfClass:NSString.class]){NSData *bytes=[command dataUsingEncoding:NSUTF8StringEncoding];command=bytes.length<32768?[NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil]:nil;}
        id params=Getter(command,@"params");
        id task=[params isKindOfClass:NSDictionary.class]?params[@"task"]:nil;
        if([task isKindOfClass:NSString.class]){NSData *b=[task dataUsingEncoding:NSUTF8StringEncoding];task=b.length<=65536?[NSJSONSerialization JSONObjectWithData:b options:0 error:nil]:nil;}
        NSDictionary *parsed=TIOTodoCreateIntent(Getter(response,@"domain"),Getter(response,@"intent"),params);
        Record(@"todo-param-inner-shape",[task isKindOfClass:NSDictionary.class]?task:@{});
        Record(@"task-nlp-shape",@{@"command":command?:@{},@"commandName":Getter(command,@"name")?:@"",@"params":params?:@{},@"commandRequestId":Getter(command,@"commandRequestId")?:@"",@"otherState":Getter(command,@"otherState")?:@{},@"parsedCreateIntent":@(parsed!=nil),@"rawData":Getter(response,@"rawData")?:@{},@"intent":Getter(response,@"intent")?:@"",@"sub":Getter(response,@"sub")?:@"",@"offline":Getter(response,@"offline")?:NSNull.null,@"finished":Getter(response,@"finished")?:NSNull.null,@"hasNextRound":Getter(response,@"hasNextRound")?:NSNull.null});
    }
    OriginalNlpProbe(self,cmd,response);
}
static void SendHook(id self,SEL cmd,NSString *channel,NSData *message,id reply) {
    // The exact event channel is discovered from SDK static names; no general
    // Flutter/Dart channel recording. Decode only RN channel events.
    if([channel isKindOfClass:NSString.class]&&[channel.lowercaseString containsString:@"rayneonet"]&&message.length<131072){
        Class codecClass=NSClassFromString(@"FlutterStandardMethodCodec");
        if([codecClass respondsToSelector:@selector(sharedInstance)]){
            id codec=((id(*)(id,SEL))objc_msgSend)(codecClass,@selector(sharedInstance));
            @try { id event=((id(*)(id,SEL,id))objc_msgSend)(codec,NSSelectorFromString(@"decodeEnvelope:"),message);
                if(EventSamples++<4)Record(@"rn-event-schema",event?:@{});
                if([event isKindOfClass:NSDictionary.class]){id d=event[@"message"]?:event[@"data"];
                    if(([d isKindOfClass:NSDictionary.class]&&[d[@"businessId"] integerValue]==22)||[event[@"businessId"] integerValue]==22)Record(@"inbound-todo",event);
                }
            }@catch(NSException *e){}
        }
    }
    OriginalSend(self,cmd,channel,message,reply);
}
__attribute__((constructor)) static void StartProbe(void) {
    dispatch_async(dispatch_get_main_queue(),^{
        if(![NSBundle.mainBundle.bundleIdentifier isEqual:@"com.rayneo.venus.pub"]||![[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] isEqual:@"67"])return;
        NSString *dir=[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/TurboIOPrivateAddon"];
        [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil];
        ProbePath=[dir stringByAppendingPathComponent:@"todo-probe-shapes-v4.jsonl"];
        if(![NSFileManager.defaultManager fileExistsAtPath:ProbePath])[NSFileManager.defaultManager createFileAtPath:ProbePath contents:NSData.data attributes:@{NSFilePosixPermissions:@0600}];
        Class cls=NSClassFromString(@"rayneo_venus_sdk_plugin.RayneoNetPluginBridge");
        Method m=class_getInstanceMethod(cls,NSSelectorFromString(@"handleMethodCall:result:"));
        Method s=class_getInstanceMethod(NSClassFromString(@"FlutterEngine"),NSSelectorFromString(@"sendOnChannel:message:binaryReply:"));
        Method nl=class_getInstanceMethod(NSClassFromString(@"rayneo_venus_sdk_plugin.AiResultListenerBridge"),NSSelectorFromString(@"onNlpResult:"));
        if(!Signature(m,4)||!Signature(s,5)||!Signature(nl,3)){Record(@"probe-not-installed",@{});return;}
        OriginalMethod=(void *)method_setImplementation(m,(IMP)MethodHook);
        OriginalSend=(void *)method_setImplementation(s,(IMP)SendHook);
        OriginalNlpProbe=(void *)method_setImplementation(nl,(IMP)NlpProbe);
        Record(@"probe-installed",@{});
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,600*NSEC_PER_SEC),dispatch_get_main_queue(),^{
            if(method_getImplementation(m)==(IMP)MethodHook)method_setImplementation(m,(IMP)OriginalMethod);
            if(method_getImplementation(s)==(IMP)SendHook)method_setImplementation(s,(IMP)OriginalSend);
            if(method_getImplementation(nl)==(IMP)NlpProbe)method_setImplementation(nl,(IMP)OriginalNlpProbe);
            Record(@"probe-restored",@{});
        });
    });
}
