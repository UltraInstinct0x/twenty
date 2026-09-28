/**
 * Functional probe for the local x-opencode-session patch.
 *
 * Loads the patched SdkProviderFactoryService straight out of the dist tree,
 * swaps globalThis.fetch for a recorder, and drives a real doGenerate() through
 * both an opencode.ai provider and a non-opencode provider. Prints PASS/FAIL per
 * assertion. Never talks to the network.
 *
 * Run inside the container:
 *   docker exec twenty-server-1 node /tmp/probe-opencode-session.js
 */
const FILE = process.env.TARGET ||
  '/app/packages/twenty-server/dist/engine/metadata-modules/ai/ai-models/services/sdk-provider-factory.service.js';
const HEADER = 'x-opencode-session';

const factoryMod = require(FILE);
const svc = new factoryMod.SdkProviderFactoryService();

let captured = [];
globalThis.fetch = async (input, init) => {
  const h = init && init.headers ? Object.fromEntries(new Headers(init.headers)) : {};
  captured.push({ url: typeof input === 'string' ? input : String(input && input.url), headers: h });
  return new Response(
    JSON.stringify({
      id: 'probe', object: 'chat.completion', created: 0, model: 'probe',
      choices: [{ index: 0, message: { role: 'assistant', content: 'ok' }, finish_reason: 'stop' }],
      usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 },
    }),
    { status: 200, headers: { 'content-type': 'application/json' } },
  );
};

const results = [];
const check = (name, ok, detail) => {
  results.push({ name, ok, detail });
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? '  :: ' + detail : ''}`);
};

const turn = (user, extra) => ({
  prompt: [
    { role: 'system', content: 'you are a crm assistant' },
    { role: 'user', content: [{ type: 'text', text: user }] },
    ...(extra || []),
  ],
});

async function generate(config, label, calls) {
  const inst = svc.buildProviderInstance(config);
  const model = inst.createModel('probe-model');
  captured = [];
  for (const c of calls) {
    await model.doGenerate(turn(c.user, c.extra));
  }
  return captured;
}

(async () => {
  const opencodeConfig = {
    npm: '@ai-sdk/openai-compatible',
    name: 'opencode-go',
    baseUrl: 'https://opencode.ai/zen/go/v1',
    apiKey: 'probe-not-a-real-key',
  };

  // 1. header present on an opencode.ai provider
  let calls = await generate(opencodeConfig, 'opencode-go', [{ user: 'list my companies' }]);
  check('opencode.ai request carries the header', !!calls[0].headers[HEADER], JSON.stringify(calls[0].headers[HEADER] || null));
  check('request still carries authorization', !!calls[0].headers.authorization);
  check('request still carries content-type', (calls[0].headers['content-type'] || '').includes('application/json'));

  // 2. stable across the turns of one conversation
  calls = await generate(opencodeConfig, 'opencode-go', [
    { user: 'list my companies' },
    { user: 'list my companies', extra: [{ role: 'assistant', content: 'sure' }, { role: 'user', content: [{ type: 'text', text: 'now only the open ones' }] }] },
  ]);
  check('same conversation keeps one session id', calls[0].headers[HEADER] === calls[1].headers[HEADER],
    `${calls[0].headers[HEADER]} / ${calls[1].headers[HEADER]}`);

  // 3. distinct across conversations
  calls = await generate(opencodeConfig, 'opencode-go', [{ user: 'what is my pipeline worth' }]);
  const other = calls[0].headers[HEADER];
  calls = await generate(opencodeConfig, 'opencode-go', [{ user: 'list my companies' }]);
  check('different conversation gets a different session id', other !== calls[0].headers[HEADER], `${other} / ${calls[0].headers[HEADER]}`);

  // 4. uuid-shaped
  check('session id is uuid shaped', /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(other), other);

  // 5. a different opencode host still matches
  calls = await generate({ ...opencodeConfig, name: 'go-2', baseUrl: 'https://opencode.ai/zen/v1' }, 'zen', [{ user: 'hi' }]);
  check('any opencode.ai host gets the header', !!calls[0].headers[HEADER]);

  // 6. untouched for every other vendor (Twenty's objection to the upstream PR)
  for (const [name, baseUrl] of [
    ['openrouter', 'https://openrouter.ai/api/v1'],
    ['openai', 'https://api.openai.com/v1'],
    ['fake-opencode-lookalike', 'https://notopencode.ai.evil.example/v1'],
  ]) {
    calls = await generate({ ...opencodeConfig, name, baseUrl }, name, [{ user: 'hi' }]);
    check(`no header for ${name}`, !calls[0].headers[HEADER], baseUrl);
    check(`request still goes out for ${name}`, calls.length === 1 && !!calls[0].headers.authorization);
  }

  const failed = results.filter((r) => !r.ok);
  console.log(`\n${results.length - failed.length}/${results.length} passed`);
  process.exit(failed.length === 0 ? 0 : 1);
})();
