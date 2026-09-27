#import "VoiceTTS.h"
#include <assert.h>

int main(void){@autoreleasepool{
    assert(TIOVoiceTTSServiceURLValid(@"wss://dashscope.aliyuncs.com/api-ws/v1/inference"));
    assert(TIOVoiceTTSServiceURLValid(@"wss://example.cn-beijing.maas.aliyuncs.com/api-ws/v1/inference"));
    assert(!TIOVoiceTTSServiceURLValid(@"https://dashscope.aliyuncs.com/api-ws/v1/inference"));
    assert(!TIOVoiceTTSServiceURLValid(@"wss://dashscope.aliyuncs.com.evil.test/api-ws/v1/inference"));
    assert(!TIOVoiceTTSServiceURLValid(@"wss://user@dashscope.aliyuncs.com/api-ws/v1/inference"));
    NSUInteger used=0;
    assert(!TIOVoiceTTSChunk(@"正在说话",NO,&used)&&used==0);
    assert([TIOVoiceTTSChunk(@"第一句话。第二句",NO,&used) isEqualToString:@"第一句话。"]&&used==5);
    assert([TIOVoiceTTSChunk(@"结束",YES,&used) isEqualToString:@"结束"]&&used==2);
    NSLog(@"PASS: TTS endpoint policy and streaming chunks");
}return 0;}
