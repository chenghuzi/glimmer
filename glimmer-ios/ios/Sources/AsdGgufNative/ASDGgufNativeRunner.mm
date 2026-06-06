#import "ASDGgufNativeRunner.h"

#include <llama/ggml-backend.h>
#include <llama/llama.h>
#include <llama/mtmd-helper.h>
#include <llama/mtmd.h>

#include <algorithm>
#include <cctype>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

NSString * const ASDGgufNativeRunnerErrorDomain = @"ASDGgufNativeRunner";

namespace {

constexpr uint32_t kContextSize = 8192;
constexpr int32_t kBatchSize = 2048;
constexpr int32_t kMaxOutputTokens = 16;
constexpr char kMediaMarker[] = "<__media__>";
constexpr char kCode9Grammar[] =
    "root ::= bit bit bit bit bit bit bit bit bit\n"
    "bit ::= \"0\" | \"1\"";

enum class NativeError : NSInteger {
    backend = 1,
    modelLoad = 2,
    contextLoad = 3,
    mmprojLoad = 4,
    unsupportedVision = 5,
    unsupportedAudio = 6,
    mediaLoad = 7,
    markerMismatch = 8,
    tokenize = 9,
    eval = 10,
    grammar = 11,
    decode = 12,
    detokenize = 13,
};

NSError * MakeError(NativeError code, NSString * message) {
    return [NSError errorWithDomain:ASDGgufNativeRunnerErrorDomain
                               code:static_cast<NSInteger>(code)
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

void AssignError(NSError ** error, NativeError code, NSString * message) {
    if (error != nullptr) {
        *error = MakeError(code, message);
    }
}

std::string ToString(NSString * value) {
    if (value == nil) {
        return {};
    }
    const char * utf8 = [value UTF8String];
    return utf8 == nullptr ? std::string() : std::string(utf8);
}

NSString * ToNSString(const std::string & value) {
    return [[NSString alloc] initWithBytes:value.data()
                                    length:value.size()
                                  encoding:NSUTF8StringEncoding];
}

std::string Trim(std::string value) {
    auto is_space = [](unsigned char ch) {
        return std::isspace(ch) != 0;
    };
    value.erase(value.begin(), std::find_if(value.begin(), value.end(), [&](char ch) {
        return !is_space(static_cast<unsigned char>(ch));
    }));
    value.erase(std::find_if(value.rbegin(), value.rend(), [&](char ch) {
        return !is_space(static_cast<unsigned char>(ch));
    }).base(), value.end());
    return value;
}

size_t CountOccurrences(const std::string & text, const std::string & needle) {
    if (needle.empty()) {
        return 0;
    }

    size_t count = 0;
    size_t offset = 0;
    while ((offset = text.find(needle, offset)) != std::string::npos) {
        count += 1;
        offset += needle.size();
    }
    return count;
}

std::string FormatGemma4Prompt(const std::string & systemPrompt, const std::string & userPrompt) {
    std::string prompt;
    const std::string system = Trim(systemPrompt);
    if (!system.empty()) {
        prompt += "<|turn>system\n";
        prompt += system;
        prompt += "<turn|>\n";
    }

    prompt += "<|turn>user\n";
    prompt += Trim(userPrompt);
    prompt += "<turn|>\n";
    prompt += "<|turn>model\n";
    return prompt;
}

int ThreadCount() {
    const unsigned int detected = std::thread::hardware_concurrency();
    if (detected == 0) {
        return 4;
    }
    return std::max(1, std::min(8, static_cast<int>(detected)));
}

void SuppressLlamaLog(enum ggml_log_level, const char *, void *) {}

void EnsureBackend() {
    static std::once_flag once;
    std::call_once(once, [] {
        llama_backend_init();
        ggml_backend_load_all();
        mtmd_helper_log_set(SuppressLlamaLog, nullptr);
    });
}

void BatchClear(llama_batch & batch) {
    batch.n_tokens = 0;
}

void BatchAdd(llama_batch & batch, llama_token token, llama_pos pos, llama_seq_id seqId, bool logits) {
    const int32_t index = batch.n_tokens;
    batch.token[index] = token;
    batch.pos[index] = pos;
    batch.n_seq_id[index] = 1;
    batch.seq_id[index][0] = seqId;
    batch.logits[index] = logits ? 1 : 0;
    batch.n_tokens += 1;
}

std::string TokenToPiece(const llama_vocab * vocab, llama_token token, bool special, NSError ** error) {
    char stackBuffer[128];
    int32_t length = llama_token_to_piece(vocab, token, stackBuffer, sizeof(stackBuffer), 0, special);
    if (length >= 0) {
        return std::string(stackBuffer, static_cast<size_t>(length));
    }

    std::vector<char> dynamicBuffer(static_cast<size_t>(-length));
    length = llama_token_to_piece(vocab, token, dynamicBuffer.data(), static_cast<int32_t>(dynamicBuffer.size()), 0, special);
    if (length < 0) {
        AssignError(error, NativeError::detokenize, @"Failed to convert generated token to text.");
        return {};
    }
    return std::string(dynamicBuffer.data(), static_cast<size_t>(length));
}

} // namespace

@implementation ASDGgufNativeRunner {
    std::mutex mutex_;
    llama_model * model_;
    llama_context * context_;
    mtmd_context * mtmd_;
    llama_batch generationBatch_;
    bool hasGenerationBatch_;
}

- (nullable instancetype)initWithModelPath:(NSString *)modelPath
                                mmprojPath:(NSString *)mmprojPath
                                     error:(NSError **)error {
    if (error != nullptr) {
        *error = nil;
    }

    self = [super init];
    if (self == nil) {
        return nil;
    }

    model_ = nullptr;
    context_ = nullptr;
    mtmd_ = nullptr;
    hasGenerationBatch_ = false;

    EnsureBackend();

    const std::string modelPathString = ToString(modelPath);
    llama_model_params modelParams = llama_model_default_params();
    modelParams.n_gpu_layers = -1;
    modelParams.use_mmap = true;

    model_ = llama_model_load_from_file(modelPathString.c_str(), modelParams);
    if (model_ == nullptr) {
        AssignError(error, NativeError::modelLoad, @"Failed to load GGUF model.");
        [self cleanupRuntime];
        return nil;
    }

    llama_context_params contextParams = llama_context_default_params();
    contextParams.n_ctx = kContextSize;
    contextParams.n_batch = kBatchSize;
    contextParams.n_seq_max = 1;
    contextParams.n_threads = ThreadCount();
    contextParams.n_threads_batch = ThreadCount();
    contextParams.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_DISABLED;

    context_ = llama_init_from_model(model_, contextParams);
    if (context_ == nullptr) {
        AssignError(error, NativeError::contextLoad, @"Failed to initialize GGUF context.");
        [self cleanupRuntime];
        return nil;
    }

    mtmd_context_params mtmdParams = mtmd_context_params_default();
    mtmdParams.use_gpu = true;
    mtmdParams.print_timings = false;
    mtmdParams.n_threads = ThreadCount();
    mtmdParams.media_marker = kMediaMarker;
    mtmdParams.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_DISABLED;
    mtmdParams.warmup = false;

    const std::string mmprojPathString = ToString(mmprojPath);
    mtmd_ = mtmd_init_from_file(mmprojPathString.c_str(), model_, mtmdParams);
    if (mtmd_ == nullptr) {
        AssignError(error, NativeError::mmprojLoad, @"Failed to load GGUF multimodal projector.");
        [self cleanupRuntime];
        return nil;
    }
    if (!mtmd_support_vision(mtmd_)) {
        AssignError(error, NativeError::unsupportedVision, @"GGUF projector does not support vision input.");
        [self cleanupRuntime];
        return nil;
    }
    if (!mtmd_support_audio(mtmd_)) {
        AssignError(error, NativeError::unsupportedAudio, @"GGUF projector does not support audio input.");
        [self cleanupRuntime];
        return nil;
    }

    generationBatch_ = llama_batch_init(1, 0, 1);
    hasGenerationBatch_ = true;
    return self;
}

- (void)cleanupRuntime {
    if (hasGenerationBatch_) {
        llama_batch_free(generationBatch_);
        hasGenerationBatch_ = false;
    }
    if (mtmd_ != nullptr) {
        mtmd_free(mtmd_);
        mtmd_ = nullptr;
    }
    if (context_ != nullptr) {
        llama_free(context_);
        context_ = nullptr;
    }
    if (model_ != nullptr) {
        llama_model_free(model_);
        model_ = nullptr;
    }
}

- (void)dealloc {
    [self cleanupRuntime];
}

- (nullable NSString *)generateWithSystemPrompt:(NSString *)systemPrompt
                                     userPrompt:(NSString *)userPrompt
                                     mediaPaths:(NSArray<NSString *> *)mediaPaths
                                          error:(NSError **)error {
    return [self generateStreamWithSystemPrompt:systemPrompt
                                     userPrompt:userPrompt
                                     mediaPaths:mediaPaths
                                        onToken:nil
                                          error:error];
}

- (nullable NSString *)generateStreamWithSystemPrompt:(NSString *)systemPrompt
                                           userPrompt:(NSString *)userPrompt
                                           mediaPaths:(NSArray<NSString *> *)mediaPaths
                                              onToken:(void (^)(NSString *))onToken
                                                error:(NSError **)error {
    if (error != nullptr) {
        *error = nil;
    }

    std::lock_guard<std::mutex> lock(mutex_);

    const std::string formattedPrompt = FormatGemma4Prompt(ToString(systemPrompt), ToString(userPrompt));
    const size_t markerCount = CountOccurrences(formattedPrompt, kMediaMarker);
    if (markerCount != mediaPaths.count) {
        AssignError(error, NativeError::markerMismatch, @"Media marker count does not match media file count.");
        return nil;
    }

    llama_memory_clear(llama_get_memory(context_), true);

    std::vector<mtmd_bitmap *> bitmaps;
    bitmaps.reserve(mediaPaths.count);
    for (NSString * path in mediaPaths) {
        mtmd_bitmap * bitmap = mtmd_helper_bitmap_init_from_file(mtmd_, ToString(path).c_str());
        if (bitmap == nullptr) {
            for (mtmd_bitmap * item : bitmaps) {
                mtmd_bitmap_free(item);
            }
            AssignError(error, NativeError::mediaLoad, @"Failed to load media file for GGUF inference.");
            return nil;
        }
        bitmaps.push_back(bitmap);
    }

    std::vector<const mtmd_bitmap *> bitmapPtrs(bitmaps.begin(), bitmaps.end());
    mtmd_input_chunks * chunks = mtmd_input_chunks_init();
    if (chunks == nullptr) {
        for (mtmd_bitmap * item : bitmaps) {
            mtmd_bitmap_free(item);
        }
        AssignError(error, NativeError::tokenize, @"Failed to allocate multimodal input chunks.");
        return nil;
    }

    mtmd_input_text text;
    text.text = formattedPrompt.c_str();
    text.add_special = true;
    text.parse_special = true;

    const int32_t tokenizeResult = mtmd_tokenize(mtmd_, chunks, &text, bitmapPtrs.data(), bitmapPtrs.size());
    if (tokenizeResult != 0) {
        mtmd_input_chunks_free(chunks);
        for (mtmd_bitmap * item : bitmaps) {
            mtmd_bitmap_free(item);
        }
        AssignError(error, NativeError::tokenize, @"Failed to tokenize multimodal prompt.");
        return nil;
    }

    llama_pos nPast = 0;
    const int32_t evalResult = mtmd_helper_eval_chunks(
        mtmd_,
        context_,
        chunks,
        nPast,
        0,
        kBatchSize,
        true,
        &nPast
    );

    mtmd_input_chunks_free(chunks);
    for (mtmd_bitmap * item : bitmaps) {
        mtmd_bitmap_free(item);
    }

    if (evalResult != 0) {
        AssignError(error, NativeError::eval, @"Failed to evaluate multimodal prompt.");
        return nil;
    }

    const llama_vocab * vocab = llama_model_get_vocab(model_);
    llama_sampler * sampler = llama_sampler_chain_init(llama_sampler_chain_default_params());
    llama_sampler * grammar = llama_sampler_init_grammar(vocab, kCode9Grammar, "root");
    if (sampler == nullptr || grammar == nullptr) {
        if (sampler != nullptr) {
            llama_sampler_free(sampler);
        }
        if (grammar != nullptr) {
            llama_sampler_free(grammar);
        }
        AssignError(error, NativeError::grammar, @"Failed to initialize grammar sampler.");
        return nil;
    }

    llama_sampler_chain_add(sampler, grammar);
    llama_sampler_chain_add(sampler, llama_sampler_init_top_k(1));
    llama_sampler_chain_add(sampler, llama_sampler_init_top_p(1.0f, 1));
    llama_sampler_chain_add(sampler, llama_sampler_init_temp(0.0f));
    llama_sampler_chain_add(sampler, llama_sampler_init_greedy());

    std::string output;
    for (int32_t index = 0; index < kMaxOutputTokens; index += 1) {
        const llama_token token = llama_sampler_sample(sampler, context_, -1);
        if (llama_vocab_is_eog(vocab, token)) {
            break;
        }

        const std::string piece = TokenToPiece(vocab, token, false, error);
        if (error != nullptr && *error != nil) {
            llama_sampler_free(sampler);
            return nil;
        }
        output += piece;
        if (onToken != nil && !piece.empty()) {
            onToken(ToNSString(piece));
        }

        BatchClear(generationBatch_);
        BatchAdd(generationBatch_, token, nPast, 0, true);
        nPast += 1;
        if (llama_decode(context_, generationBatch_) != 0) {
            llama_sampler_free(sampler);
            AssignError(error, NativeError::decode, @"Failed to decode generated token.");
            return nil;
        }
    }

    llama_sampler_free(sampler);
    return ToNSString(output);
}

@end
