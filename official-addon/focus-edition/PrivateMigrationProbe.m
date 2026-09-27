// Private test-device-only migration helper. NEVER include in the shipped IPA.
// Reads only the known app executable and this addon's two configured key items.
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach/mach.h>
#include <string.h>
static NSString *Key(NSString *account){
    NSDictionary *q=@{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,(__bridge id)kSecAttrService:@"io.turboio.official-private-addon",(__bridge id)kSecAttrAccount:account,(__bridge id)kSecReturnData:@YES};
    CFTypeRef result=NULL;if(SecItemCopyMatching((__bridge CFDictionaryRef)q,&result)!=errSecSuccess)return nil;
    return [[NSString alloc]initWithData:CFBridgingRelease(result) encoding:NSUTF8StringEncoding];
}
static void Export(void){@autoreleasepool{
    NSBundle *bundle=NSBundle.mainBundle;
    if(![bundle.bundleIdentifier isEqual:@"com.rayneo.venus.pub"]||![[[bundle objectForInfoDictionaryKey:@"CFBundleVersion"] description] isEqual:@"67"])return;
    uint32_t imageIndex=UINT32_MAX;for(uint32_t i=0;i<_dyld_image_count();i++){const char *n=_dyld_get_image_name(i);if(n&&[[NSString stringWithUTF8String:n] isEqual:bundle.executablePath]){imageIndex=i;break;}}
    if(imageIndex==UINT32_MAX)return;
    const struct mach_header_64 *h=(const void *)_dyld_get_image_header(imageIndex);if(!h||h->magic!=MH_MAGIC_64)return;
    const uint8_t wanted[16]={0xee,0xea,0x85,0xe5,0x41,0x14,0x31,0x3c,0xb6,0x51,0x73,0xc9,0x0a,0x6b,0x5d,0x3c};
    const uint8_t *p=(const uint8_t *)(h+1),*end=p+h->sizeofcmds;BOOL match=NO;const struct encryption_info_command_64 *crypt=NULL;
    for(uint32_t i=0;i<h->ncmds;i++){if(p+8>end)return;const struct load_command *c=(const void *)p;if(c->cmdsize<8||p+c->cmdsize>end)return;if(c->cmd==LC_UUID&&c->cmdsize>=24)match=!memcmp(((const struct uuid_command *)c)->uuid,wanted,16);if(c->cmd==LC_ENCRYPTION_INFO_64&&c->cmdsize>=24)crypt=(const void *)c;p+=c->cmdsize;}
    if(!match||!crypt||!crypt->cryptsize)return;
    NSString *dir=[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/TurboIOPrivateAddon/PrivateMigration-20260911-v2"];
    if([NSFileManager.defaultManager fileExistsAtPath:dir])return;
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil];
    NSMutableData *data=[[NSData dataWithContentsOfFile:bundle.executablePath] mutableCopy];
    uint64_t off=crypt->cryptoff,len=crypt->cryptsize;BOOL copied=NO;
    if(data&&off+len<=data.length){
        p=(const uint8_t *)(h+1);
        for(uint32_t i=0;i<h->ncmds;i++){const struct load_command *c=(const void *)p;if(c->cmd==LC_SEGMENT_64){const struct segment_command_64 *s=(const void *)c;if(off>=s->fileoff&&off+len<=s->fileoff+s->filesize){vm_size_t n=0;vm_address_t source=s->vmaddr+_dyld_get_image_vmaddr_slide(imageIndex)+(off-s->fileoff);kern_return_t r=vm_read_overwrite(mach_task_self(),source,len,(vm_address_t)data.mutableBytes+off,&n);copied=r==KERN_SUCCESS&&n==len;break;}}p+=c->cmdsize;}
        if(copied){size_t at=(const uint8_t *)crypt-(const uint8_t *)h;uint32_t zero=0;[data replaceBytesInRange:NSMakeRange(at+16,4) withBytes:&zero];copied=[data writeToFile:[dir stringByAppendingPathComponent:@"Runner.research.bin"] options:NSDataWritingWithoutOverwriting error:nil];}
    }
    NSUserDefaults *prefs=[[NSUserDefaults alloc]initWithSuiteName:@"io.turboio.official-private-addon"];
    NSString *endpoint=[prefs stringForKey:@"endpoint"],*model=[prefs stringForKey:@"model"];
    NSString *modelKey=endpoint.length?Key(endpoint):nil,*searchKey=Key(@"https://api.search.tinyfish.ai");
    BOOL config=NO;
    if(endpoint.length&&model.length&&modelKey.length&&searchKey.length){
        NSDictionary *bootstrap=@{@"schema":@1,@"endpoint":endpoint,@"model":model,@"modelKey":modelKey,@"tinyfishKey":searchKey,@"tinyfishEnabled":@([prefs boolForKey:@"tinyfishEnabled"]),@"deepseekDisableThinking":@([prefs boolForKey:@"deepseekDisableThinking"]),@"voiceExitCommands":@([prefs boolForKey:@"voiceExitCommands"])};
        NSData *j=[NSJSONSerialization dataWithJSONObject:bootstrap options:0 error:nil];config=[j writeToFile:[dir stringByAppendingPathComponent:@"TurboIOPrivateBootstrap.json"] options:NSDataWritingWithoutOverwriting error:nil];
    }
    for(NSString *name in @[@"Runner.research.bin",@"TurboIOPrivateBootstrap.json"])[NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions:@0600,NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication} ofItemAtPath:[dir stringByAppendingPathComponent:name] error:nil];
    NSDictionary *report=@{@"executableCopy":@(copied),@"privateConfig":@(config),@"officialCredentialsRead":@NO};
    [[NSJSONSerialization dataWithJSONObject:report options:0 error:nil] writeToFile:[dir stringByAppendingPathComponent:@"report.json"] atomically:YES];
}}
__attribute__((constructor)) static void Load(void){dispatch_async(dispatch_get_main_queue(),^{Export();});}
