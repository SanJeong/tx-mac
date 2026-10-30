#import <Foundation/Foundation.h>

FOUNDATION_EXPORT NSString * const TXLanguageDidChangeNotification;
FOUNDATION_EXPORT NSString *TXL(NSString *key);
FOUNDATION_EXPORT NSString *TXLanguageCode(void);
FOUNDATION_EXPORT void TXSetLanguageCode(NSString *code);
FOUNDATION_EXPORT BOOL TXRunLocalizationSelfCheck(void);
