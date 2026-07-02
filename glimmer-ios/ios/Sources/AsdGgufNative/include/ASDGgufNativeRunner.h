#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const ASDGgufNativeRunnerErrorDomain;

@interface ASDGgufNativeRunner : NSObject

- (instancetype)init NS_UNAVAILABLE;

- (nullable instancetype)initWithModelPath:(NSString *)modelPath
                                mmprojPath:(NSString *)mmprojPath
                                     error:(NSError **)error NS_DESIGNATED_INITIALIZER;

/// 当前 mmproj 是否支持音频输入。纯视觉投影器为 NO，调用方应跳过音频。
@property (nonatomic, readonly) BOOL supportsAudio;

/// prefill 进度回调：tokensDone/tokensTotal 为已求值/总 token 数
/// （图像 chunk 按其实际 token 数计权）。在推理线程上同步调用。
typedef void (^ASDGgufPrefillProgressBlock)(int64_t tokensDone, int64_t tokensTotal);

- (nullable NSString *)generateWithSystemPrompt:(NSString *)systemPrompt
                                     userPrompt:(NSString *)userPrompt
                                     mediaPaths:(NSArray<NSString *> *)mediaPaths
                                       progress:(nullable ASDGgufPrefillProgressBlock)progress
                                          error:(NSError **)error;

- (BOOL)beginExplanationSessionWithSystemPrompt:(NSString *)systemPrompt
                                     userPrompt:(NSString *)userPrompt
                               assistantContext:(NSString *)assistantContext
                                     mediaPaths:(NSArray<NSString *> *)mediaPaths
                                          error:(NSError **)error;

/// 分类刚结束时的快路径：不清 KV cache，在同一会话上用纯文本追加
/// 「解释任务指令 + 预填结果上下文」，媒体不重新编码。
/// 仅在最近一次 generate 成功且之后未清空会话时可用，否则返回 NO，
/// 调用方应回落到 beginExplanationSessionWithSystemPrompt 全量 prefill。
- (BOOL)continueExplanationSessionWithUserInstruction:(NSString *)userInstruction
                                     assistantContext:(NSString *)assistantContext
                                                error:(NSError **)error;

- (nullable NSString *)sendExplanationUserMessage:(NSString *)message
                                  maxOutputTokens:(NSInteger)maxOutputTokens
                                            error:(NSError **)error;

- (void)invalidateExplanationSession;

@end

NS_ASSUME_NONNULL_END
