#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Decodes a legacy `streamtyped` (NSArchiver) blob and returns the plain text
/// of the archived NSAttributedString.
///
/// Why this exists: `message.attributedBody` in chat.db is a typedstream, not a
/// keyed archive. `NSKeyedUnarchiver` cannot read it (verified: it returns nil
/// with an NSCocoaErrorDomain error), and `NSUnarchiver`, which can, is
/// deprecated and marked unavailable in Swift. So the call is made here, from
/// Objective-C, behind one function.
///
/// Verified against a real chat.db on macOS 26.5: `NSUnarchiver` is still
/// present and decodes these blobs into NSConcreteAttributedString. Should
/// Apple finally remove it, this returns nil and the Swift caller falls back to
/// `TypedStreamScanner`.
///
/// Returns nil rather than raising for any malformed input.
NSString * _Nullable OTPDecodeTypedStreamString(NSData *data);

/// Whether the legacy unarchiver is available in this process at all. Lets the
/// Swift side decide whether to even try, and lets tests assert which decode
/// path they exercised.
BOOL OTPTypedStreamDecoderAvailable(void);

/// Archives a string as a typedstream, for test fixtures only. Returns nil if
/// the legacy archiver is unavailable.
NSData * _Nullable OTPEncodeTypedStreamString(NSString *string);

NS_ASSUME_NONNULL_END
