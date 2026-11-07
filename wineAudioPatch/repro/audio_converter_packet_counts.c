/* SPDX-License-Identifier: LGPL-2.1-or-later
 * Offline synthetic PCM only. Never creates an AudioUnit or queries a device.
 */
#include <AudioToolbox/AudioToolbox.h>
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
struct input { int16_t *pcm; UInt32 total, offset; };
static OSStatus provide(AudioConverterRef converter,UInt32 *packets,AudioBufferList *data,
                        AudioStreamPacketDescription **description,void *user)
{
    (void)converter;
    struct input *input=user;
    UInt32 available=input->total-input->offset;
    if(*packets>available)*packets=available;
    data->mNumberBuffers=1;data->mBuffers[0].mNumberChannels=1;
    data->mBuffers[0].mDataByteSize=*packets*2;
    data->mBuffers[0].mData=*packets?input->pcm+input->offset:NULL;
    input->offset+=*packets;if(description)*description=NULL;return noErr;
}
static AudioStreamBasicDescription format(double rate)
{
    AudioStreamBasicDescription result={0};result.mSampleRate=rate;result.mFormatID=kAudioFormatLinearPCM;
    result.mFormatFlags=kAudioFormatFlagIsSignedInteger|kAudioFormatFlagIsPacked;
    result.mBytesPerPacket=result.mBytesPerFrame=2;result.mFramesPerPacket=1;
    result.mChannelsPerFrame=1;result.mBitsPerChannel=16;return result;
}
int main(void)
{
    const struct {double input,output;UInt32 frames,request;} cases[]={{8000,8000,17,80},{48000,8000,2048,80},{8000,48000,257,240}};
    unsigned short_outputs=0;
    for(unsigned c=0;c<sizeof(cases)/sizeof(cases[0]);c++){
        AudioStreamBasicDescription in=format(cases[c].input),out=format(cases[c].output);
        AudioConverterRef converter=NULL;assert(AudioConverterNew(&in,&out,&converter)==noErr);
        struct input input={calloc(cases[c].frames,sizeof(int16_t)),cases[c].frames,0};
        for(UInt32 i=0;i<input.total;i++)input.pcm[i]=(int16_t)((i%101)*17-850);
        unsigned ended=0,total=0;
        for(unsigned call=0;call<64;call++){
            int16_t output[1024];memset(output,0x55,sizeof(output));
            AudioBufferList data={.mNumberBuffers=1,.mBuffers={{.mNumberChannels=1,.mDataByteSize=cases[c].request*2,.mData=output}}};
            UInt32 packets=cases[c].request;
            OSStatus result=AudioConverterFillComplexBuffer(converter,provide,&input,&packets,&data,NULL);
            assert(result==noErr&&packets<=cases[c].request&&data.mBuffers[0].mDataByteSize==packets*2);
            printf("rate=%.0f->%.0f call=%u requested=%u actual=%u bytes=%u consumed=%u status=%d\n",cases[c].input,cases[c].output,call,cases[c].request,(unsigned)packets,(unsigned)data.mBuffers[0].mDataByteSize,(unsigned)input.offset,(int)result);
            if(packets>0&&packets<cases[c].request)short_outputs++;
            if(c==0&&call==0)assert(packets==17&&!memcmp(output,input.pcm,17*2));
            total+=packets;if(!packets){ended=1;break;}
        }
        assert(ended&&input.offset==input.total&&total>0);free(input.pcm);assert(AudioConverterDispose(converter)==noErr);
    }
    assert(short_outputs>0);puts("PASS: real AudioConverter rewrites packet in/out count, byte count agrees; no device/AudioUnit");return 0;
}
