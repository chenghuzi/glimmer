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

/// 流式生成：每解出一个 token 就回调 `onToken(piece)`，最终返回完整 output。
/// onToken 可能在后台队列被调用，UI 层需自行回主线程。
- (nullable NSString *)generateStreamWithSystemPrompt:(NSString *)systemPrompt
                                           userPrompt:(NSString *)userPrompt
                                           mediaPaths:(NSArray<NSString *> *)mediaPaths
                                              onToken:(void (^_Nullable)(NSString *piece))onToken
                                                error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
