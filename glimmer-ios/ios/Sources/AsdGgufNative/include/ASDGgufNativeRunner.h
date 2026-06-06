#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const ASDGgufNativeRunnerErrorDomain;

@interface ASDGgufNativeRunner : NSObject

- (instancetype)init NS_UNAVAILABLE;

- (nullable instancetype)initWithModelPath:(NSString *)modelPath
                                mmprojPath:(NSString *)mmprojPath
                                     error:(NSError **)error NS_DESIGNATED_INITIALIZER;

- (nullable NSString *)generateWithSystemPrompt:(NSString *)systemPrompt
                                     userPrompt:(NSString *)userPrompt
                                     mediaPaths:(NSArray<NSString *> *)mediaPaths
                                          error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
