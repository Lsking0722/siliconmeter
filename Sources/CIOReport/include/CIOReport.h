//
//  CIOReport.h
//  Declarations for Apple's private IOReport framework, exposed to Swift.
//
//  Adapted from SiliconScope (Sources/CIOReport/include/ktop_ioreport.h),
//  Copyright (c) 2026 Kennt Kim (Calida Lab), MIT License. Declarations only.
//
//  There is no SDK stub for IOReport; the executable links with
//  `-undefined dynamic_lookup` and the symbols resolve at runtime via dyld.
//  "Copy"/"Create" functions return +1 (retained) values; "Get" functions return
//  unretained values.
//
#ifndef CIOREPORT_H
#define CIOREPORT_H

#include <CoreFoundation/CoreFoundation.h>
#include <stdint.h>

typedef struct IOReportSubscriptionRef *IOReportSubscriptionRef;

// Channel discovery.
extern CFMutableDictionaryRef IOReportCopyChannelsInGroup(CFStringRef group, CFStringRef subgroup, uint64_t a, uint64_t b, uint64_t c);
extern void IOReportMergeChannels(CFMutableDictionaryRef dst, CFMutableDictionaryRef src, CFTypeRef nullPtr);

// Subscription and sampling.
extern IOReportSubscriptionRef IOReportCreateSubscription(void *a, CFMutableDictionaryRef desiredChannels, CFMutableDictionaryRef *subbedChannels, uint64_t channelID, CFTypeRef b);
extern CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef sub, CFMutableDictionaryRef subbedChannels, CFTypeRef a);
extern CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef prev, CFDictionaryRef current, CFTypeRef a);

// Per-sample iteration. Return 0 from the block to continue.
typedef int (^sm_ioreport_iterate_block)(CFDictionaryRef channel);
extern void IOReportIterate(CFDictionaryRef samples, sm_ioreport_iterate_block block);

// Per-channel metadata. Format 1 = simple, 2 = state, 4 = simple array.
extern CFStringRef IOReportChannelGetGroup(CFDictionaryRef channel);
extern CFStringRef IOReportChannelGetSubGroup(CFDictionaryRef channel);
extern CFStringRef IOReportChannelGetChannelName(CFDictionaryRef channel);
extern int IOReportChannelGetFormat(CFDictionaryRef channel);

// State-format readers.
extern CFStringRef IOReportChannelGetUnitLabel(CFDictionaryRef channel);
extern int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef channel, int32_t *unused);
extern CFMutableDictionaryRef IOReportCopyAllChannels(uint64_t a, uint64_t b);

extern int IOReportStateGetCount(CFDictionaryRef channel);
extern uint64_t IOReportStateGetResidency(CFDictionaryRef channel, int index);
extern CFStringRef IOReportStateGetNameForIndex(CFDictionaryRef channel, int index);

#endif /* CIOREPORT_H */
