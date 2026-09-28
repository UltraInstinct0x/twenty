import { createHash, randomUUID } from 'node:crypto';

import { Injectable, Logger } from '@nestjs/common';

import { createAmazonBedrock } from '@ai-sdk/amazon-bedrock';
import { createAnthropic, type AnthropicProvider } from '@ai-sdk/anthropic';
import { createAzure } from '@ai-sdk/azure';
import { createGoogleGenerativeAI } from '@ai-sdk/google';
import { createMistral } from '@ai-sdk/mistral';
import { createOpenAI, type OpenAIProvider } from '@ai-sdk/openai';
import { createOpenAICompatible } from '@ai-sdk/openai-compatible';
import { createTypeSafeAi } from '@ai-sdk/typesafe-ai';
import { createXai, type XaiProvider } from '@ai-sdk/xai';
import { fromNodeProviderChain } from '@aws-sdk/credential-providers';
import {
  wrapLanguageModel,
  type LanguageModel,
  type LanguageModelMiddleware,
  type TranscriptionModel,
} from 'ai';
import { type AiSdkPackage } from 'twenty-shared/ai';
import { isDefined } from 'twenty-shared/utils';

import {
  AI_SDK_ANTHROPIC,
  AI_SDK_AZURE,
  AI_SDK_BEDROCK,
  AI_SDK_GOOGLE,
  AI_SDK_MISTRAL,
  AI_SDK_OPENAI,
  AI_SDK_OPENAI_COMPATIBLE,
  AI_SDK_TYPESAFE_AI,
  AI_SDK_XAI,
} from 'src/engine/metadata-modules/ai/ai-models/constants/ai-sdk-package.const';
import { sanitizeGeminiToolResultRefsMiddleware } from 'src/engine/metadata-modules/ai/ai-models/middleware/sanitize-gemini-tool-result-refs.middleware';
import { type AiEvaluationModel } from 'src/engine/metadata-modules/ai/ai-models/types/ai-evaluation-model.type';
import { type AiProviderConfig } from 'src/engine/metadata-modules/ai/ai-models/types/ai-provider-config.type';
import { getEvaluationModelFactory } from 'src/engine/metadata-modules/ai/ai-models/utils/get-evaluation-model-factory.util';
import { getTranscriptionModelFactory } from 'src/engine/metadata-modules/ai/ai-models/utils/get-transcription-model-factory.util';

// ---------------------------------------------------------------------------
// LOCAL PATCH: per-conversation `x-opencode-session` header
//
// OpenCode Go (https://opencode.ai/zen/go/v1) rejects any inference request that
// does not carry an `x-opencode-session` header. The Vercel AI SDK never sends
// it, and upstream declined to add vendor-specific header injection
// (twentyhq/twenty#25289 closed unmerged), so the header is derived here from
// the outgoing request body instead: sha256(system prompt + first user turn)
// formatted as a UUID. Stable across the turns of one conversation, distinct
// between conversations, opaque to OpenCode.
//
// Attached ONLY when the provider baseUrl points at opencode.ai: every other
// vendor's request is byte-for-byte unchanged, which is exactly what upstream's
// objection to the PR was about.
//
// See PATCHES.md. Retire this block once upstream passes custom provider
// headers through to the SDK, or once OpenCode Go stops requiring the header.
// ---------------------------------------------------------------------------
const OPENCODE_SESSION_HEADER = 'x-opencode-session';

const OPENCODE_BASE_URL_PATTERN = /(^|[./])opencode\.ai([/:]|$)/;

const isOpencodeBaseUrl = (baseUrl?: string): boolean =>
  typeof baseUrl === 'string' && OPENCODE_BASE_URL_PATTERN.test(baseUrl);

const opencodeSessionIdFromBody = (body: unknown): string => {
  let seed: string | null = null;

  if (typeof body === 'string' && body.length > 0) {
    try {
      const parsed = JSON.parse(body) as
        | { messages?: Array<{ role?: string; content?: unknown }> }
        | Array<{ role?: string; content?: unknown }>;
      const messages = Array.isArray(parsed)
        ? parsed
        : Array.isArray(parsed?.messages)
          ? parsed.messages
          : null;

      if (messages && messages.length > 0) {
        const systemMessage = messages.find((m) => m?.role === 'system');
        const firstUserMessage = messages.find((m) => m?.role === 'user');

        seed = JSON.stringify([
          systemMessage?.content ?? null,
          firstUserMessage?.content ?? null,
        ]);
      }
    } catch {
      // Body is not JSON: fall through and hash the raw body.
    }

    if (seed === null) {
      seed = body;
    }
  }

  const hex = createHash('sha256')
    .update(seed ?? randomUUID())
    .digest('hex')
    .slice(0, 32);

  return [
    hex.slice(0, 8),
    hex.slice(8, 12),
    hex.slice(12, 16),
    hex.slice(16, 20),
    hex.slice(20, 32),
  ].join('-');
};

const withOpencodeSession = <T extends (...args: any[]) => any>(
  config: AiProviderConfig,
  factory: T,
): T => {
  if (!isOpencodeBaseUrl(config?.baseUrl)) {
    return factory;
  }

  return ((settings: Record<string, any>) => {
    const innerFetch = settings?.fetch ?? globalThis.fetch;

    return factory({
      ...settings,
      fetch: async (input: any, init: any) => {
        const headers = new Headers(init?.headers);

        if (!headers.has(OPENCODE_SESSION_HEADER)) {
          headers.set(
            OPENCODE_SESSION_HEADER,
            opencodeSessionIdFromBody(init?.body),
          );
        }

        return innerFetch(input, { ...init, headers });
      },
    });
  }) as unknown as T;
};
// ------------------------ end of local patch ------------------------------

export type AiSdkProviderInstance = {
  // Absent on providers that serve no language model at all, such as an
  // evaluation-only provider.
  createModel?: (modelId: string) => LanguageModel;
  // Absent on providers with no speech-to-text API.
  createTranscriptionModel?: (modelId: string) => TranscriptionModel;
  // Absent on providers with no evaluation API.
  createEvaluationModel?: (modelId: string) => AiEvaluationModel;
  rawProvider: unknown;
  sdkPackage: AiSdkPackage;
};

@Injectable()
export class SdkProviderFactoryService {
  private readonly logger = new Logger(SdkProviderFactoryService.name);
  private readonly providerInstances = new Map<string, AiSdkProviderInstance>();

  createProvider(
    providerName: string,
    config: AiProviderConfig,
  ): AiSdkProviderInstance {
    const cached = this.providerInstances.get(providerName);

    if (cached) {
      return cached;
    }

    const instance = this.buildProviderInstance(config);

    this.providerInstances.set(providerName, instance);

    return instance;
  }

  getRawProvider<T>(
    providerName: string,
    ...allowedPackages: string[]
  ): T | undefined {
    const instance = this.providerInstances.get(providerName);

    if (!instance || !allowedPackages.includes(instance.sdkPackage)) {
      return undefined;
    }

    return instance.rawProvider as T;
  }

  getRawAnthropicProvider(providerName: string): AnthropicProvider | undefined {
    return this.getRawProvider<AnthropicProvider>(
      providerName,
      AI_SDK_ANTHROPIC,
    );
  }

  getRawOpenAIProvider(providerName: string): OpenAIProvider | undefined {
    return this.getRawProvider<OpenAIProvider>(providerName, AI_SDK_OPENAI);
  }

  getRawXaiProvider(providerName: string): XaiProvider | undefined {
    return this.getRawProvider<XaiProvider>(providerName, AI_SDK_XAI);
  }

  clearCache(): void {
    this.providerInstances.clear();
  }

  private toProviderInstance(
    provider: unknown,
    sdkPackage: AiSdkPackage,
    createModel?: (modelId: string) => LanguageModel,
  ): AiSdkProviderInstance {
    const createTranscriptionModel = getTranscriptionModelFactory(provider);
    const createEvaluationModel = getEvaluationModelFactory(provider);

    return {
      ...(isDefined(createModel) && { createModel }),
      ...(isDefined(createTranscriptionModel) && { createTranscriptionModel }),
      ...(isDefined(createEvaluationModel) && { createEvaluationModel }),
      rawProvider: provider,
      sdkPackage,
    };
  }

  private buildProviderInstance(
    config: AiProviderConfig,
  ): AiSdkProviderInstance {
    switch (config.npm) {
      case AI_SDK_OPENAI:
        return this.buildStandardProvider(config, createOpenAI);
      case AI_SDK_ANTHROPIC:
        return this.buildStandardProvider(config, createAnthropic);
      case AI_SDK_GOOGLE:
        return this.buildStandardProvider(config, createGoogleGenerativeAI, {
          middleware: sanitizeGeminiToolResultRefsMiddleware,
        });
      case AI_SDK_MISTRAL:
        return this.buildStandardProvider(config, createMistral);
      case AI_SDK_XAI:
        return this.buildXaiProvider(config);
      case AI_SDK_BEDROCK:
        return this.buildBedrockProvider(config);
      case AI_SDK_OPENAI_COMPATIBLE:
        return this.buildOpenAiCompatibleProvider(config);
      case AI_SDK_AZURE:
        return this.buildAzureProvider(config);
      case AI_SDK_TYPESAFE_AI:
        return this.buildTypeSafeAiProvider(config);
      default:
        throw new Error(`Unsupported SDK package: ${config.npm}`);
    }
  }

  private buildStandardProvider(
    config: AiProviderConfig,
    factory: (opts: { apiKey?: string; baseURL?: string }) => CallableFunction,
    options?: { middleware?: LanguageModelMiddleware },
  ): AiSdkProviderInstance {
    const provider = withOpencodeSession(config, factory)({
      ...(config.apiKey && { apiKey: config.apiKey }),
      ...(config.baseUrl && { baseURL: config.baseUrl }),
    });

    return this.toProviderInstance(provider, config.npm, (modelId: string) => {
      const model = (provider as CallableFunction)(modelId);

      return options?.middleware
        ? wrapLanguageModel({ model, middleware: options.middleware })
        : model;
    });
  }

  private buildXaiProvider(config: AiProviderConfig): AiSdkProviderInstance {
    const provider = withOpencodeSession(config, createXai)({
      ...(config.apiKey && { apiKey: config.apiKey }),
      ...(config.baseUrl && { baseURL: config.baseUrl }),
    });

    return this.toProviderInstance(provider, AI_SDK_XAI, (modelId: string) =>
      provider.responses(modelId),
    );
  }

  private buildBedrockProvider(
    config: AiProviderConfig,
  ): AiSdkProviderInstance {
    const region = config.region ?? 'us-east-1';
    const useRoleCredentials = config.authType === 'role';
    const awsCredentialProvider = useRoleCredentials
      ? fromNodeProviderChain({ clientConfig: { region } })
      : undefined;

    const provider = withOpencodeSession(config, createAmazonBedrock)({
      region,
      ...(awsCredentialProvider && {
        credentialProvider: async () => {
          const credentials = await awsCredentialProvider();

          return {
            accessKeyId: credentials.accessKeyId,
            secretAccessKey: credentials.secretAccessKey,
            sessionToken: credentials.sessionToken,
          };
        },
      }),
      ...(!useRoleCredentials &&
        config.accessKeyId &&
        config.secretAccessKey && {
          accessKeyId: config.accessKeyId,
          secretAccessKey: config.secretAccessKey,
          sessionToken: config.sessionToken,
        }),
    });

    return this.toProviderInstance(
      provider,
      AI_SDK_BEDROCK,
      (modelId: string) => provider(modelId),
    );
  }

  private buildOpenAiCompatibleProvider(
    config: AiProviderConfig,
  ): AiSdkProviderInstance {
    if (!config.baseUrl) {
      throw new Error('baseUrl is required for openai-compatible providers');
    }

    const provider = withOpencodeSession(config, createOpenAICompatible)({
      name: config.name ?? 'openai-compatible',
      baseURL: config.baseUrl,
      ...(config.apiKey && { apiKey: config.apiKey }),
    });

    return this.toProviderInstance(
      provider,
      AI_SDK_OPENAI_COMPATIBLE,
      (modelId: string) => provider(modelId),
    );
  }

  // Evaluation-only: the provider serves no language model, so the instance
  // carries no createModel and the registry skips its models for chat.
  private buildTypeSafeAiProvider(
    config: AiProviderConfig,
  ): AiSdkProviderInstance {
    const provider = createTypeSafeAi({
      ...(config.apiKey && { apiKey: config.apiKey }),
      ...(config.baseUrl && { baseURL: config.baseUrl }),
    });

    return this.toProviderInstance(provider, AI_SDK_TYPESAFE_AI);
  }

  private buildAzureProvider(config: AiProviderConfig): AiSdkProviderInstance {
    if (!config.baseUrl) {
      throw new Error('baseUrl is required for Azure OpenAI providers');
    }

    const provider = withOpencodeSession(config, createAzure)({
      baseURL: config.baseUrl,
      ...(config.apiKey && { apiKey: config.apiKey }),
    });

    return this.toProviderInstance(provider, AI_SDK_AZURE, (modelId: string) =>
      provider(modelId),
    );
  }
}
