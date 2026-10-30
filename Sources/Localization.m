#import "Localization.h"

NSString * const TXLanguageDidChangeNotification = @"TX6MacLanguageDidChange";
static NSString * const TXLanguageDefaultsKey = @"TX6Mac.language";
static NSArray<NSString *> *TXSupportedLanguages(void) { return @[@"en", @"ko", @"ja"]; }
NSString *TXLanguageCode(void) {
    NSString *code = [NSUserDefaults.standardUserDefaults stringForKey:TXLanguageDefaultsKey];
    return [TXSupportedLanguages() containsObject:code] ? code : @"system";
}
static NSString *TXResolvedLanguage(void) {
    NSString *selection = TXLanguageCode();
    if (![selection isEqualToString:@"system"]) return selection;
    for (NSString *language in NSLocale.preferredLanguages) {
        NSString *code = [[language stringByReplacingOccurrencesOfString:@"_" withString:@"-"] componentsSeparatedByString:@"-"].firstObject.lowercaseString;
        if ([TXSupportedLanguages() containsObject:code]) return code;
    }
    return @"en";
}
static NSDictionary<NSString *, NSString *> *TXCatalog(NSString *language) {
    static NSDictionary *catalogs;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *loaded = [NSMutableDictionary dictionary];
        for (NSString *code in TXSupportedLanguages()) {
            NSString *path = [NSBundle.mainBundle pathForResource:@"Localizable" ofType:@"strings" inDirectory:nil forLocalization:code];
            loaded[code] = path ? ([NSDictionary dictionaryWithContentsOfFile:path] ?: @{}) : @{};
        }
        catalogs = loaded.copy;
    });
    return catalogs[language];
}
NSString *TXL(NSString *key) {
    if (!key.length) return key ?: @"";
    return TXCatalog(TXResolvedLanguage())[key] ?: TXCatalog(@"en")[key] ?: key;
}
void TXSetLanguageCode(NSString *code) {
    NSString *validated = [TXSupportedLanguages() containsObject:code] ? code : @"system";
    if ([TXLanguageCode() isEqualToString:validated]) return;
    [NSUserDefaults.standardUserDefaults setObject:validated forKey:TXLanguageDefaultsKey];
    void (^notify)(void) = ^{ [NSNotificationCenter.defaultCenter postNotificationName:TXLanguageDidChangeNotification object:nil]; };
    if (NSThread.isMainThread) notify(); else dispatch_async(dispatch_get_main_queue(), notify);
}
static NSArray<NSString *> *TXFormatTokens(NSString *text) {
    static NSRegularExpression *pattern;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ pattern = [NSRegularExpression regularExpressionWithPattern:@"%(?:[0-9]+\\$)?[-+ #0]*(?:[0-9]+|\\*)?(?:\\.(?:[0-9]+|\\*))?(?:hh|ll|[hljztL])?[@diuoxXfFeEgGaAcCsSpn%]" options:0 error:NULL]; });
    NSMutableArray *tokens = [NSMutableArray array];
    for (NSTextCheckingResult *match in [pattern matchesInString:text options:0 range:NSMakeRange(0, text.length)]) [tokens addObject:[text substringWithRange:match.range]];
    return tokens;
}
BOOL TXRunLocalizationSelfCheck(void) {
    NSDictionary *reference = TXCatalog(@"ko");
    if (reference.count < 100) { NSLog(@"Localization catalog missing or incomplete"); return NO; }
    for (NSString *language in TXSupportedLanguages()) {
        NSDictionary *catalog = TXCatalog(language);
        if (![[NSSet setWithArray:reference.allKeys] isEqualToSet:[NSSet setWithArray:catalog.allKeys]]) return NO;
        for (NSString *key in reference) {
            NSString *translation = catalog[key];
            if (![translation isKindOfClass:NSString.class] || !translation.length || ![TXFormatTokens(key) isEqualToArray:TXFormatTokens(translation)]) { NSLog(@"Invalid localization: %@ / %@", language, key); return NO; }
        }
        NSString *path = [NSBundle.mainBundle pathForResource:@"InfoPlist" ofType:@"strings" inDirectory:nil forLocalization:language];
        NSDictionary *privacy = path ? [NSDictionary dictionaryWithContentsOfFile:path] : nil;
        for (NSString *key in @[@"NSAudioCaptureUsageDescription", @"NSBluetoothAlwaysUsageDescription"]) if (![privacy[key] length]) return NO;
    }
    return YES;
}
