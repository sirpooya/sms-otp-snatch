#import "OTPTypedStream.h"
#import <objc/message.h>
#import <objc/runtime.h>

// The magic prefix every typedstream blob starts with: 0x04 0x0B "streamtyped".
static const unsigned char kTypedStreamMagic[] = {
    0x04, 0x0B, 's', 't', 'r', 'e', 'a', 'm', 't', 'y', 'p', 'e', 'd'
};

static BOOL OTPLooksLikeTypedStream(NSData *data) {
    if (data.length < sizeof(kTypedStreamMagic)) { return NO; }
    return memcmp(data.bytes, kTypedStreamMagic, sizeof(kTypedStreamMagic)) == 0;
}

static Class OTPLegacyUnarchiverClass(void) {
    // Looked up by name on purpose: the symbol is unavailable to Swift and
    // deprecated in ObjC, so linking against it directly invites a build
    // failure on some future SDK. A name lookup degrades to nil instead.
    static Class cls = Nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cls = NSClassFromString(@"NSUnarchiver"); });
    return cls;
}

static Class OTPLegacyArchiverClass(void) {
    static Class cls = Nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cls = NSClassFromString(@"NSArchiver"); });
    return cls;
}

BOOL OTPTypedStreamDecoderAvailable(void) {
    Class cls = OTPLegacyUnarchiverClass();
    if (cls == Nil) { return NO; }
    return [cls respondsToSelector:NSSelectorFromString(@"unarchiveObjectWithData:")];
}

NSString * _Nullable OTPDecodeTypedStreamString(NSData *data) {
    if (data.length == 0) { return nil; }
    if (!OTPLooksLikeTypedStream(data)) { return nil; }

    Class cls = OTPLegacyUnarchiverClass();
    SEL sel = NSSelectorFromString(@"unarchiveObjectWithData:");
    if (cls == Nil || ![cls respondsToSelector:sel]) { return nil; }

    id decoded = nil;
    @try {
        // NSUnarchiver raises on malformed archives instead of returning nil,
        // and chat.db is not a trusted input, so this stays inside @try.
        id (*send)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;
        decoded = send(cls, sel, data);
    } @catch (NSException *exception) {
        return nil;
    }

    if (decoded == nil) { return nil; }
    if ([decoded isKindOfClass:[NSAttributedString class]]) {
        NSString *s = [(NSAttributedString *)decoded string];
        return s.length > 0 ? s : nil;
    }
    if ([decoded isKindOfClass:[NSString class]]) {
        NSString *s = (NSString *)decoded;
        return s.length > 0 ? s : nil;
    }
    return nil;
}

NSData * _Nullable OTPEncodeTypedStreamString(NSString *string) {
    Class cls = OTPLegacyArchiverClass();
    SEL sel = NSSelectorFromString(@"archivedDataWithRootObject:");
    if (cls == Nil || ![cls respondsToSelector:sel]) { return nil; }
    NSAttributedString *attributed = [[NSAttributedString alloc] initWithString:string];
    @try {
        id (*send)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;
        return send(cls, sel, attributed);
    } @catch (NSException *exception) {
        return nil;
    }
}
