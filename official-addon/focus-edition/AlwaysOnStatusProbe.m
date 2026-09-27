// Private, one-shot, read-only metadata inspection. No capture/configure/clear calls.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <dlfcn.h>
static BOOL MatchingRunner(const struct mach_header *h){
    if(!h||h->magic!=MH_MAGIC_64||h->filetype!=MH_EXECUTE)return NO;
    const struct mach_header_64 *m=(const void *)h;const uint8_t *p=(const void *)(m+1),*end=p+m->sizeofcmds;
    for(uint32_t i=0;i<m->ncmds&&p+sizeof(struct load_command)<=end;i++){
        const struct load_command *c=(const void *)p;if(c->cmdsize<sizeof(*c)||p+c->cmdsize>end)return NO;
        if(c->cmd==LC_UUID&&c->cmdsize>=sizeof(struct uuid_command)){NSUUID *uuid=[[NSUUID alloc]initWithUUIDBytes:((const struct uuid_command *)c)->uuid];return [uuid.UUIDString isEqual:@"EEEA85E5-4114-313C-B651-73C90A6B5D3C"];}p+=c->cmdsize;
    }return NO;
}
__attribute__((constructor))static void ReadAlwaysOnStatus(void){dispatch_async(dispatch_get_main_queue(),^{
    NSMutableDictionary *report=[NSMutableDictionary dictionaryWithDictionary:@{@"readOnly":@YES,@"configureCalled":@NO}];
    Class cls=NSClassFromString(@"rayneo_venus_sdk_plugin.AlwaysOnDebugAudioController");
    void *slot=dlsym(RTLD_DEFAULT,"$s23rayneo_venus_sdk_plugin28AlwaysOnDebugAudioControllerC6sharedACvpZ");
    Dl_info info={0};BOOL valid=slot&&dladdr(slot,&info)&&MatchingRunner(info.dli_fbase);
    report[@"classPresent"]=@(cls!=Nil);report[@"exactSymbolInVerifiedRunner"]=@(valid);
    if(valid&&cls){
        // This exported Swift stored-property symbol is an object reference, not a getter ABI.
        id controller=*(__unsafe_unretained id *)slot;
        if(controller&&object_getClass(controller)==cls){
            SEL sel=NSSelectorFromString(@"getStatus");Method method=class_getInstanceMethod(cls,sel);char *type=method?method_copyReturnType(method):NULL;
            if(method&&type&&type[0]=='@'&&method_getNumberOfArguments(method)==2){
                @try{id value=((id(*)(id,SEL))objc_msgSend)(controller,sel);if([value isKindOfClass:NSDictionary.class]){
                    report[@"statusKeys"]=[[value allKeys] sortedArrayUsingSelector:@selector(compare:)];
                    NSMutableDictionary *flags=[NSMutableDictionary new],*paths=[NSMutableDictionary new];
                    for(NSString *key in value){id v=value[key];if([v isKindOfClass:NSNumber.class])flags[key]=v;
                        if([v isKindOfClass:NSString.class]&&[v hasPrefix:[NSHomeDirectory() stringByAppendingString:@"/"]])paths[key]=[v substringFromIndex:NSHomeDirectory().length];}
                    report[@"numericStatus"]=flags;report[@"ownSandboxPaths"]=paths;
                }}@catch(NSException *e){report[@"statusReadFailed"]=@YES;}
            }free(type);
        }else report[@"singletonNotReady"]=@YES;
    }
    NSURL *file=[NSURL fileURLWithPath:[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/TurboIOPrivateAddon/alwayson-status-readonly.json"]];
    NSData *data=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
    [data writeToURL:file options:NSDataWritingAtomic error:nil];[NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions:@0600} ofItemAtPath:file.path error:nil];
});}
