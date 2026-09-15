
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#import <math.h>

#pragma mark - Config

static CGFloat gScale = 0.55;
static BOOL gDisableShadows = YES;
static BOOL gDisableCrowd = YES;
static BOOL gDisableWeather = YES;
static BOOL gDisableGrass = YES;
static BOOL gDisableBloom = YES;
static BOOL gConfigLoaded = NO;

enum {
    DLSCatNone    = 0,
    DLSCatShadow  = 1 << 0,
    DLSCatCrowd   = 1 << 1,
    DLSCatWeather = 1 << 2,
    DLSCatGrass   = 1 << 3,
    DLSCatBloom   = 1 << 4,
};

static NSString *DLSHomePath(NSString *name) {
    return [NSHomeDirectory() stringByAppendingPathComponent:
            [@"Documents" stringByAppendingPathComponent:name]];
}

static BOOL DLSParseBool(NSString *value, BOOL fallback) {
    if (!value) return fallback;
    NSString *v = [[value stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    if ([v isEqualToString:@"1"] || [v isEqualToString:@"true"] ||
        [v isEqualToString:@"yes"] || [v isEqualToString:@"on"]) return YES;
    if ([v isEqualToString:@"0"] || [v isEqualToString:@"false"] ||
        [v isEqualToString:@"no"] || [v isEqualToString:@"off"]) return NO;
    return fallback;
}

static void DLSLoadConfig(void) {
    if (gConfigLoaded) return;
    gConfigLoaded = YES;

    NSString *path = DLSHomePath(@"dlslite.txt");
    NSError *err = nil;
    NSString *raw = [NSString stringWithContentsOfFile:path
                                              encoding:NSUTF8StringEncoding
                                                 error:&err];

    if (raw.length == 0) {
        // Backward compatibility with V1.
        NSString *old = [NSString stringWithContentsOfFile:DLSHomePath(@"dlslowres.txt")
                                                  encoding:NSUTF8StringEncoding
                                                     error:nil];
        if (old.length > 0) {
            double x = old.doubleValue;
            if (x > 1.0) x /= 100.0;
            if (x >= 0.40 && x <= 1.00) gScale = (CGFloat)x;
        }
        return;
    }

    for (NSString *line in [raw componentsSeparatedByCharactersInSet:
                            [NSCharacterSet newlineCharacterSet]]) {
        NSString *s = [line stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (s.length == 0 || [s hasPrefix:@"#"]) continue;

        NSArray *parts = [s componentsSeparatedByString:@"="];
        if (parts.count < 2) continue;

        NSString *key = [[parts[0] stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceCharacterSet]] lowercaseString];
        NSString *value = [parts[1] stringByTrimmingCharactersInSet:
                            [NSCharacterSet whitespaceCharacterSet]];

        if ([key isEqualToString:@"scale"]) {
            double x = value.doubleValue;
            if (x > 1.0) x /= 100.0;
            if (x >= 0.40 && x <= 1.00) gScale = (CGFloat)x;
        } else if ([key isEqualToString:@"disable_shadows"]) {
            gDisableShadows = DLSParseBool(value, gDisableShadows);
        } else if ([key isEqualToString:@"disable_crowd"]) {
            gDisableCrowd = DLSParseBool(value, gDisableCrowd);
        } else if ([key isEqualToString:@"disable_weather"]) {
            gDisableWeather = DLSParseBool(value, gDisableWeather);
        } else if ([key isEqualToString:@"disable_grass"]) {
            gDisableGrass = DLSParseBool(value, gDisableGrass);
        } else if ([key isEqualToString:@"disable_bloom"]) {
            gDisableBloom = DLSParseBool(value, gDisableBloom);
        }
    }
}

#pragma mark - Counters / logs

static volatile uint64_t gPipelinesSeen = 0;
static volatile uint64_t gShadowPSO = 0;
static volatile uint64_t gCrowdPSO = 0;
static volatile uint64_t gWeatherPSO = 0;
static volatile uint64_t gGrassPSO = 0;
static volatile uint64_t gBloomPSO = 0;
static volatile uint64_t gSkippedDraws = 0;
static volatile uint64_t gSkippedShadow = 0;
static volatile uint64_t gSkippedCrowd = 0;
static volatile uint64_t gSkippedWeather = 0;
static volatile uint64_t gSkippedGrass = 0;
static volatile uint64_t gSkippedBloom = 0;
static volatile uint64_t gDeviceHooks = 0;
static volatile uint64_t gEncoderHooks = 0;

static NSMutableSet<NSString *> *gLoggedPipelineNames;
static dispatch_queue_t gLogQueue;

static void DLSWriteStatus(void) {
    DLSLoadConfig();

    NSString *status = [NSString stringWithFormat:
        @"DLS LiteFX V2 active\n"
         "scale=%.3f\n"
         "disable_shadows=%d\n"
         "disable_crowd=%d\n"
         "disable_weather=%d\n"
         "disable_grass=%d\n"
         "disable_bloom=%d\n"
         "device_hooks=%llu\n"
         "encoder_hooks=%llu\n"
         "pipelines_seen=%llu\n"
         "shadow_pipelines=%llu\n"
         "crowd_pipelines=%llu\n"
         "weather_pipelines=%llu\n"
         "grass_pipelines=%llu\n"
         "bloom_pipelines=%llu\n"
         "skipped_draws=%llu\n"
         "skipped_shadow=%llu\n"
         "skipped_crowd=%llu\n"
         "skipped_weather=%llu\n"
         "skipped_grass=%llu\n"
         "skipped_bloom=%llu\n",
         gScale,
         gDisableShadows, gDisableCrowd, gDisableWeather,
         gDisableGrass, gDisableBloom,
         gDeviceHooks, gEncoderHooks, gPipelinesSeen,
         gShadowPSO, gCrowdPSO, gWeatherPSO, gGrassPSO, gBloomPSO,
         gSkippedDraws, gSkippedShadow, gSkippedCrowd,
         gSkippedWeather, gSkippedGrass, gSkippedBloom];

    [status writeToFile:DLSHomePath(@"dlslite_status.txt")
             atomically:YES
               encoding:NSUTF8StringEncoding
                  error:nil];
}

static void DLSLogPipeline(NSString *name, NSUInteger cat) {
    if (name.length == 0) return;
    if (!gLogQueue) gLogQueue = dispatch_queue_create("dlslite.log", DISPATCH_QUEUE_SERIAL);

    dispatch_async(gLogQueue, ^{
        if (!gLoggedPipelineNames) gLoggedPipelineNames = [NSMutableSet set];
        @synchronized (gLoggedPipelineNames) {
            if ([gLoggedPipelineNames containsObject:name]) return;
            if (gLoggedPipelineNames.count >= 250) return;
            [gLoggedPipelineNames addObject:name];
        }

        NSString *line = [NSString stringWithFormat:@"%@ | cat=0x%lx\n",
                          name, (unsigned long)cat];
        NSString *path = DLSHomePath(@"dlslite_pipelines.txt");
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!fh) {
            [@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
            fh = [NSFileHandle fileHandleForWritingAtPath:path];
        }
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    });
}

#pragma mark - Category classifier

static NSUInteger DLSCategoryForString(NSString *src) {
    if (src.length == 0) return DLSCatNone;
    NSString *s = [src lowercaseString];
    NSUInteger c = DLSCatNone;

    if ([s containsString:@"shadow"]) c |= DLSCatShadow;
    if ([s containsString:@"crowd"] || [s containsString:@"spectator"]) c |= DLSCatCrowd;
    if ([s containsString:@"precip"] || [s containsString:@"rain"] ||
        [s containsString:@"snow"] || [s containsString:@"weather"]) c |= DLSCatWeather;
    if ([s containsString:@"grass"]) c |= DLSCatGrass;
    if ([s containsString:@"bloom"]) c |= DLSCatBloom;

    return c;
}

static BOOL DLSCategoryBlocked(NSUInteger c) {
    if ((c & DLSCatShadow) && gDisableShadows) return YES;
    if ((c & DLSCatCrowd) && gDisableCrowd) return YES;
    if ((c & DLSCatWeather) && gDisableWeather) return YES;
    if ((c & DLSCatGrass) && gDisableGrass) return YES;
    if ((c & DLSCatBloom) && gDisableBloom) return YES;
    return NO;
}

static void DLSCountSkip(NSUInteger c) {
    __sync_fetch_and_add(&gSkippedDraws, 1);
    if (c & DLSCatShadow) __sync_fetch_and_add(&gSkippedShadow, 1);
    if (c & DLSCatCrowd) __sync_fetch_and_add(&gSkippedCrowd, 1);
    if (c & DLSCatWeather) __sync_fetch_and_add(&gSkippedWeather, 1);
    if (c & DLSCatGrass) __sync_fetch_and_add(&gSkippedGrass, 1);
    if (c & DLSCatBloom) __sync_fetch_and_add(&gSkippedBloom, 1);
}

#pragma mark - Low-resolution hook (confirmed working in V1)

static const void *kDLSLastScaledSizeKey = &kDLSLastScaledSizeKey;
static BOOL gDrawableLogged = NO;

%hook CAMetalLayer

- (void)setDrawableSize:(CGSize)size {
    DLSLoadConfig();

    if (gScale >= 0.999 || size.width < 256.0 || size.height < 256.0) {
        %orig(size);
        return;
    }

    NSValue *lastValue = objc_getAssociatedObject(self, kDLSLastScaledSizeKey);
    if (lastValue) {
        CGSize last = [lastValue CGSizeValue];
        if (fabs(last.width - size.width) < 0.5 &&
            fabs(last.height - size.height) < 0.5) {
            %orig(size);
            return;
        }
    }

    CGSize scaled = CGSizeMake(floor(size.width * gScale),
                               floor(size.height * gScale));
    if (scaled.width < 320.0) scaled.width = 320.0;
    if (scaled.height < 180.0) scaled.height = 180.0;

    objc_setAssociatedObject(self, kDLSLastScaledSizeKey,
                             [NSValue valueWithCGSize:scaled],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    if (!gDrawableLogged) {
        gDrawableLogged = YES;
        NSString *line = [NSString stringWithFormat:
            @"drawable_input=%.0fx%.0f\ndrawable_output=%.0fx%.0f\n",
            size.width, size.height, scaled.width, scaled.height];
        [line writeToFile:DLSHomePath(@"dlslite_drawable.txt")
               atomically:YES
                 encoding:NSUTF8StringEncoding
                    error:nil];
    }

    %orig(scaled);
}

%end

#pragma mark - Dynamic Metal hooks

static const void *kDLSPipelineCategoryKey = &kDLSPipelineCategoryKey;
static const void *kDLSEncoderCategoryKey = &kDLSEncoderCategoryKey;

static NSMutableDictionary<NSString *, NSValue *> *gOrigNewPSO;
static NSMutableDictionary<NSString *, NSValue *> *gOrigSetPSO;
static NSMutableDictionary<NSString *, NSValue *> *gOrigDrawA;
static NSMutableDictionary<NSString *, NSValue *> *gOrigDrawB;
static NSMutableDictionary<NSString *, NSValue *> *gOrigDrawC;
static NSMutableDictionary<NSString *, NSValue *> *gOrigDrawD;
static NSMutableDictionary<NSString *, NSValue *> *gOrigDrawE;
static NSMutableDictionary<NSString *, NSValue *> *gOrigDrawF;
static NSMutableSet<NSString *> *gHooked;

static NSString *DLSKey(Class cls, SEL sel) {
    return [NSString stringWithFormat:@"%@|%@", NSStringFromClass(cls), NSStringFromSelector(sel)];
}

static IMP DLSFindIMP(NSMutableDictionary<NSString *, NSValue *> *map, id obj, SEL sel) {
    Class c = object_getClass(obj);
    while (c) {
        NSValue *v = map[DLSKey(c, sel)];
        if (v) return [v pointerValue];
        c = class_getSuperclass(c);
    }
    return NULL;
}

static BOOL DLSClassHasDirectMethod(Class cls, SEL sel, Method *outMethod) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    BOOL found = NO;
    Method foundMethod = NULL;

    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == sel) {
            found = YES;
            foundMethod = methods[i];
            break;
        }
    }
    free(methods);

    if (outMethod) *outMethod = foundMethod;
    return found;
}

static void DLSInstallMethodHook(Class cls, SEL sel, IMP replacement,
                                 NSMutableDictionary<NSString *, NSValue *> *map,
                                 volatile uint64_t *counter) {
    if (!cls || !sel) return;

    NSString *key = DLSKey(cls, sel);
    @synchronized (gHooked) {
        if ([gHooked containsObject:key]) return;
    }

    Method m = NULL;
    if (!DLSClassHasDirectMethod(cls, sel, &m) || !m) return;

    IMP orig = method_getImplementation(m);
    if (!orig || orig == replacement) return;

    map[key] = [NSValue valueWithPointer:orig];
    method_setImplementation(m, replacement);

    @synchronized (gHooked) {
        [gHooked addObject:key];
    }
    if (counter) __sync_fetch_and_add(counter, 1);
}

static id DLSNewRenderPSO(id self, SEL _cmd,
                          MTLRenderPipelineDescriptor *desc,
                          NSError **error) {
    IMP imp = DLSFindIMP(gOrigNewPSO, self, _cmd);
    if (!imp) return nil;

    typedef id (*Fn)(id, SEL, MTLRenderPipelineDescriptor *, NSError **);
    id pso = ((Fn)imp)(self, _cmd, desc, error);

    NSString *label = desc.label ?: @"";
    NSString *vname = desc.vertexFunction.name ?: @"";
    NSString *fname = desc.fragmentFunction.name ?: @"";
    NSString *joined = [NSString stringWithFormat:@"%@ | %@ | %@", label, vname, fname];

    NSUInteger cat = DLSCategoryForString(joined);
    if (pso) objc_setAssociatedObject(pso, kDLSPipelineCategoryKey,
                                      @(cat), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    __sync_fetch_and_add(&gPipelinesSeen, 1);
    if (cat & DLSCatShadow) __sync_fetch_and_add(&gShadowPSO, 1);
    if (cat & DLSCatCrowd) __sync_fetch_and_add(&gCrowdPSO, 1);
    if (cat & DLSCatWeather) __sync_fetch_and_add(&gWeatherPSO, 1);
    if (cat & DLSCatGrass) __sync_fetch_and_add(&gGrassPSO, 1);
    if (cat & DLSCatBloom) __sync_fetch_and_add(&gBloomPSO, 1);

    DLSLogPipeline(joined, cat);
    return pso;
}

static void DLSSetRenderPSO(id self, SEL _cmd, id<MTLRenderPipelineState> pso) {
    NSNumber *n = objc_getAssociatedObject(pso, kDLSPipelineCategoryKey);
    objc_setAssociatedObject(self, kDLSEncoderCategoryKey,
                             n ?: @(0), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    IMP imp = DLSFindIMP(gOrigSetPSO, self, _cmd);
    if (!imp) return;
    typedef void (*Fn)(id, SEL, id<MTLRenderPipelineState>);
    ((Fn)imp)(self, _cmd, pso);
}

static BOOL DLSShouldSkip(id encoder, NSUInteger *outCat) {
    DLSLoadConfig();
    NSNumber *n = objc_getAssociatedObject(encoder, kDLSEncoderCategoryKey);
    NSUInteger cat = n ? n.unsignedIntegerValue : 0;
    if (outCat) *outCat = cat;
    return cat != 0 && DLSCategoryBlocked(cat);
}

static void DLSDrawA(id self, SEL _cmd, MTLPrimitiveType p, NSUInteger start, NSUInteger count) {
    NSUInteger cat=0; if (DLSShouldSkip(self,&cat)) { DLSCountSkip(cat); return; }
    IMP imp=DLSFindIMP(gOrigDrawA,self,_cmd); if(!imp)return;
    typedef void(*Fn)(id,SEL,MTLPrimitiveType,NSUInteger,NSUInteger);
    ((Fn)imp)(self,_cmd,p,start,count);
}
static void DLSDrawB(id self, SEL _cmd, MTLPrimitiveType p, NSUInteger start, NSUInteger count, NSUInteger inst) {
    NSUInteger cat=0; if (DLSShouldSkip(self,&cat)) { DLSCountSkip(cat); return; }
    IMP imp=DLSFindIMP(gOrigDrawB,self,_cmd); if(!imp)return;
    typedef void(*Fn)(id,SEL,MTLPrimitiveType,NSUInteger,NSUInteger,NSUInteger);
    ((Fn)imp)(self,_cmd,p,start,count,inst);
}
static void DLSDrawC(id self, SEL _cmd, MTLPrimitiveType p, NSUInteger start, NSUInteger count, NSUInteger inst, NSUInteger base) {
    NSUInteger cat=0; if (DLSShouldSkip(self,&cat)) { DLSCountSkip(cat); return; }
    IMP imp=DLSFindIMP(gOrigDrawC,self,_cmd); if(!imp)return;
    typedef void(*Fn)(id,SEL,MTLPrimitiveType,NSUInteger,NSUInteger,NSUInteger,NSUInteger);
    ((Fn)imp)(self,_cmd,p,start,count,inst,base);
}
static void DLSDrawD(id self, SEL _cmd, MTLPrimitiveType p, NSUInteger count, MTLIndexType t, id<MTLBuffer> buf, NSUInteger off) {
    NSUInteger cat=0; if (DLSShouldSkip(self,&cat)) { DLSCountSkip(cat); return; }
    IMP imp=DLSFindIMP(gOrigDrawD,self,_cmd); if(!imp)return;
    typedef void(*Fn)(id,SEL,MTLPrimitiveType,NSUInteger,MTLIndexType,id<MTLBuffer>,NSUInteger);
    ((Fn)imp)(self,_cmd,p,count,t,buf,off);
}
static void DLSDrawE(id self, SEL _cmd, MTLPrimitiveType p, NSUInteger count, MTLIndexType t, id<MTLBuffer> buf, NSUInteger off, NSUInteger inst) {
    NSUInteger cat=0; if (DLSShouldSkip(self,&cat)) { DLSCountSkip(cat); return; }
    IMP imp=DLSFindIMP(gOrigDrawE,self,_cmd); if(!imp)return;
    typedef void(*Fn)(id,SEL,MTLPrimitiveType,NSUInteger,MTLIndexType,id<MTLBuffer>,NSUInteger,NSUInteger);
    ((Fn)imp)(self,_cmd,p,count,t,buf,off,inst);
}
static void DLSDrawF(id self, SEL _cmd, MTLPrimitiveType p, NSUInteger count, MTLIndexType t, id<MTLBuffer> buf, NSUInteger off, NSUInteger inst, NSInteger baseVertex, NSUInteger baseInstance) {
    NSUInteger cat=0; if (DLSShouldSkip(self,&cat)) { DLSCountSkip(cat); return; }
    IMP imp=DLSFindIMP(gOrigDrawF,self,_cmd); if(!imp)return;
    typedef void(*Fn)(id,SEL,MTLPrimitiveType,NSUInteger,MTLIndexType,id<MTLBuffer>,NSUInteger,NSUInteger,NSInteger,NSUInteger);
    ((Fn)imp)(self,_cmd,p,count,t,buf,off,inst,baseVertex,baseInstance);
}

static void DLSScanMetalClasses(void) {
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;

    Class *classes = (Class *)malloc(sizeof(Class) * count);
    count = objc_getClassList(classes, count);

    Protocol *deviceProto = objc_getProtocol("MTLDevice");
    Protocol *encoderProto = objc_getProtocol("MTLRenderCommandEncoder");

    SEL newPSO = @selector(newRenderPipelineStateWithDescriptor:error:);
    SEL setPSO = @selector(setRenderPipelineState:);

    SEL drawA = @selector(drawPrimitives:vertexStart:vertexCount:);
    SEL drawB = @selector(drawPrimitives:vertexStart:vertexCount:instanceCount:);
    SEL drawC = @selector(drawPrimitives:vertexStart:vertexCount:instanceCount:baseInstance:);
    SEL drawD = @selector(drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:);
    SEL drawE = @selector(drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:instanceCount:);
    SEL drawF = @selector(drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:instanceCount:baseVertex:baseInstance:);

    for (int i = 0; i < count; i++) {
        Class cls = classes[i];

        if (deviceProto && class_conformsToProtocol(cls, deviceProto)) {
            DLSInstallMethodHook(cls, newPSO, (IMP)DLSNewRenderPSO,
                                 gOrigNewPSO, &gDeviceHooks);
        }

        if (encoderProto && class_conformsToProtocol(cls, encoderProto)) {
            DLSInstallMethodHook(cls, setPSO, (IMP)DLSSetRenderPSO,
                                 gOrigSetPSO, &gEncoderHooks);
            DLSInstallMethodHook(cls, drawA, (IMP)DLSDrawA, gOrigDrawA, NULL);
            DLSInstallMethodHook(cls, drawB, (IMP)DLSDrawB, gOrigDrawB, NULL);
            DLSInstallMethodHook(cls, drawC, (IMP)DLSDrawC, gOrigDrawC, NULL);
            DLSInstallMethodHook(cls, drawD, (IMP)DLSDrawD, gOrigDrawD, NULL);
            DLSInstallMethodHook(cls, drawE, (IMP)DLSDrawE, gOrigDrawE, NULL);
            DLSInstallMethodHook(cls, drawF, (IMP)DLSDrawF, gOrigDrawF, NULL);
        }
    }

    free(classes);
}

static void DLSCreateDefaultConfigIfMissing(void) {
    NSString *path = DLSHomePath(@"dlslite.txt");
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) return;

    NSString *cfg =
        @"# DLS LiteFX V2\n"
         "scale=55\n"
         "disable_shadows=1\n"
         "disable_crowd=1\n"
         "disable_weather=1\n"
         "disable_grass=1\n"
         "disable_bloom=1\n";

    [cfg writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

%ctor {
    @autoreleasepool {
        gOrigNewPSO = [NSMutableDictionary dictionary];
        gOrigSetPSO = [NSMutableDictionary dictionary];
        gOrigDrawA = [NSMutableDictionary dictionary];
        gOrigDrawB = [NSMutableDictionary dictionary];
        gOrigDrawC = [NSMutableDictionary dictionary];
        gOrigDrawD = [NSMutableDictionary dictionary];
        gOrigDrawE = [NSMutableDictionary dictionary];
        gOrigDrawF = [NSMutableDictionary dictionary];
        gHooked = [NSMutableSet set];

        DLSCreateDefaultConfigIfMissing();
        DLSLoadConfig();

        // Force Metal framework/device class to load, then scan.
        (void)MTLCreateSystemDefaultDevice();
        DLSScanMetalClasses();

        NSArray<NSNumber *> *delays = @[@0.25, @0.75, @1.5, @3.0, @6.0, @10.0];
        for (NSNumber *n in delays) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(n.doubleValue * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                DLSScanMetalClasses();
                DLSWriteStatus();
            });
        }

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            DLSWriteStatus();
        });
    }
}
