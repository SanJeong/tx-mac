#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
extern NSString * const TXSceneErrorDomain;
typedef NS_ENUM(NSInteger, TXSceneErrorCode) {
    TXSceneErrorInvalidData=1,
    TXSceneErrorUnsupportedVersion=2,
    TXSceneErrorInvalidName=3,
    TXSceneErrorDuplicateName=4,
    TXSceneErrorLimitReached=5,
    TXSceneErrorNotFound=6,
    TXSceneErrorReadOnly=7
};

@interface TXSceneStore : NSObject
@property(nonatomic,readonly) NSArray<NSDictionary*> *scenes;
@property(nonatomic,readonly) BOOL readOnly;
- (instancetype)initWithDefaults:(NSUserDefaults*)defaults;
- (BOOL)reload:(NSError * _Nullable * _Nullable)error;
// Canonical snapshots are v2; reading v1 never writes defaults.
+ (nullable NSDictionary*)canonicalSnapshot:(id)value error:(NSError * _Nullable * _Nullable)error;
+ (nullable NSDictionary<NSString*,NSDictionary*>*)canonicalAppGroups:(id)value error:(NSError * _Nullable * _Nullable)error;
+ (nullable NSArray<NSString*>*)bundleIDsForAssignment:(NSString*)assignment appGroups:(NSDictionary*)appGroups error:(NSError * _Nullable * _Nullable)error;
+ (BOOL)validateAssignments:(NSArray*)assignments appGroups:(NSDictionary*)appGroups chromeTabs:(BOOL)chromeTabs error:(NSError * _Nullable * _Nullable)error;
+ (BOOL)snapshot:(NSDictionary*)a equals:(NSDictionary*)b;
- (nullable NSDictionary*)sceneWithID:(NSString*)sceneID;
- (nullable NSDictionary*)addSceneNamed:(NSString*)name snapshot:(NSDictionary*)snapshot error:(NSError * _Nullable * _Nullable)error;
- (BOOL)updateSceneID:(NSString*)sceneID snapshot:(NSDictionary*)snapshot error:(NSError * _Nullable * _Nullable)error;
- (BOOL)renameSceneID:(NSString*)sceneID name:(NSString*)name error:(NSError * _Nullable * _Nullable)error;
- (BOOL)removeSceneID:(NSString*)sceneID error:(NSError * _Nullable * _Nullable)error;
- (BOOL)restoreEntry:(NSDictionary*)entry atIndex:(NSUInteger)index error:(NSError * _Nullable * _Nullable)error;
@end
BOOL TXRunSceneStoreSelfCheck(void);
NS_ASSUME_NONNULL_END
