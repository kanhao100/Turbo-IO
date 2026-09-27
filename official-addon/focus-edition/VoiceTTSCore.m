#import "VoiceTTS.h"

BOOL TIOVoiceTTSServiceURLValid(NSString *url){
    if(![url isKindOfClass:NSString.class]||url.length>300)return NO;
    NSURLComponents *c=[NSURLComponents componentsWithString:url];NSString *host=c.host.lowercaseString;
    return [c.scheme.lowercaseString isEqualToString:@"wss"]&&
        ([host isEqualToString:@"dashscope.aliyuncs.com"]||
         ([host hasSuffix:@".maas.aliyuncs.com"]&&host.length>@".maas.aliyuncs.com".length))&&
        [c.path isEqualToString:@"/api-ws/v1/inference"]&&
        (!c.port||c.port.integerValue==443)&&!c.user&&!c.password&&!c.query&&!c.fragment;
}
NSString *TIOVoiceTTSService(void){
    NSUserDefaults *prefs=[[NSUserDefaults alloc]initWithSuiteName:@"io.turboio.official-private-addon"];
    NSString *custom=[prefs stringForKey:@"ttsEndpoint"];
    return TIOVoiceTTSServiceURLValid(custom)?custom:@"wss://dashscope.aliyuncs.com/api-ws/v1/inference";
}
NSString *TIOVoiceTTSChunk(NSString *pending, BOOL final, NSUInteger *consumed){
    if(consumed)*consumed=0;
    if(![pending isKindOfClass:NSString.class]||!pending.length)return nil;
    NSUInteger limit=MIN(pending.length,180),cut=NSNotFound;
    NSCharacterSet *stop=[NSCharacterSet characterSetWithCharactersInString:@"。！？!?；;\n"];
    NSCharacterSet *soft=[NSCharacterSet characterSetWithCharactersInString:@"，,、：: "];
    for(NSUInteger i=0;i<limit;i++){unichar c=[pending characterAtIndex:i];
        if([stop characterIsMember:c]&&i>=3){cut=i+1;break;}
        if(i>=65&&[soft characterIsMember:c]){cut=i+1;break;}}
    if(cut==NSNotFound){if(limit>=140)cut=limit;else if(final)cut=limit;else return nil;}
    if(cut<pending.length&&cut>0){unichar a=[pending characterAtIndex:cut-1],b=[pending characterAtIndex:cut];
        if(a>=0xD800&&a<=0xDBFF&&b>=0xDC00&&b<=0xDFFF)cut++;}
    if(consumed)*consumed=cut;
    return [[pending substringToIndex:cut] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}
