#!/usr/bin/env python3
"""Generate the patched `sdk-provider-factory.service.js` for the local
x-opencode-session patch, from the PRISTINE file shipped in a Twenty image.

    usage: generate-dist-patch.py <pristine.js> <out.js>

Why a dist-level transform instead of compiling the TypeScript source:

  The official twenty-server image ships compiled JS only. Verified inside
  twentycrm/twenty:v2.43.0: there is no `src/`, no `tsconfig.json`, and
  `require('typescript/package.json')` throws, so nothing can be compiled in the
  image. A full source build is possible but the Dockerfile's own comment marks
  the frontend bundle as memory intensive and runs it with
  `NODE_OPTIONS=--max-old-space-size=8192`, which this 11 GB host cannot spare
  while the CRM is serving.

  So the patch ships as a mechanically generated transform of the compiled file.
  It carries the same logic as the TypeScript patch on branch
  `goku/opencode-session-header` (helpers + five wrapped provider factories), and
  every anchor below is asserted, so a change in upstream's emitted shape fails
  loudly instead of silently producing a wrong file.

Exit codes: 0 = written, 1 = anchor missing / already patched.
"""

import re
import sys
from pathlib import Path

# The provider factories that can serve chat requests. `createTypeSafeAi` is
# deliberately absent: it is an evaluation-only provider (`buildTypeSafeAiProvider`
# registers no createModel), so no chat request can flow through it.
FACTORY_CALLS = (
    "createXai",
    "createAmazonBedrock",
    "createOpenAICompatible",
    "createAzure",
)

DECORATE_ANCHOR = "function _ts_decorate("
STANDARD_ANCHOR = "        const provider = factory({\n"
STANDARD_REPLACEMENT = "        const provider = _withOpencodeSession(config, factory)({\n"

# tsc emits imported bindings as `(0, _xai.createXai)({`; the local alias varies
# per build, so match it generically.
SITE_RE = re.compile(
    r"const provider = \(0, _(?P<mod>[A-Za-z0-9_]+)\.(?P<fn>"
    + "|".join(FACTORY_CALLS)
    + r")\)\(\{"
)

HELPERS = r'''
// ---- local patch: per-conversation x-opencode-session header -----------------
const _ociCrypto = require("node:crypto");
const _OPENCODE_SESSION_HEADER = "x-opencode-session";
function _isOpencodeBaseUrl(baseUrl) {
    return typeof baseUrl === "string" && /(^|[./])opencode\.ai([/:]|$)/.test(baseUrl);
}
function _opencodeSessionIdFromBody(body) {
    var seed = null;
    try {
        var text = typeof body === "string" ? body : (body == null ? "" : String(body));
        if (text) {
            try {
                var parsed = JSON.parse(text);
                var messages = Array.isArray(parsed) ? parsed : (parsed && Array.isArray(parsed.messages) ? parsed.messages : null);
                if (messages && messages.length > 0) {
                    var system = messages.find(function(m) { return m && m.role === "system"; });
                    var firstUser = messages.find(function(m) { return m && m.role === "user"; });
                    seed = JSON.stringify([
                        system ? system.content : null,
                        firstUser ? firstUser.content : null
                    ]);
                }
            } catch (_) {}
            if (seed === null) seed = text;
        }
    } catch (_) {}
    var hex = _ociCrypto
        .createHash("sha256")
        .update(seed === null ? _ociCrypto.randomUUID() : seed)
        .digest("hex")
        .slice(0, 32);
    return [hex.slice(0, 8), hex.slice(8, 12), hex.slice(12, 16), hex.slice(16, 20), hex.slice(20, 32)].join("-");
}
function _copyHeaders(init) {
    var headers = new Headers();
    var raw = init && init.headers;
    if (!raw) return headers;
    if (typeof raw.forEach === "function") {
        raw.forEach(function(value, key) { headers.append(key, value); });
    } else if (Array.isArray(raw)) {
        raw.forEach(function(pair) { headers.append(pair[0], pair[1]); });
    } else {
        Object.keys(raw).forEach(function(key) {
            if (raw[key] !== undefined && raw[key] !== null) headers.append(key, String(raw[key]));
        });
    }
    return headers;
}
function _withOpencodeSession(config, factory) {
    if (!_isOpencodeBaseUrl(config && config.baseUrl)) return factory;
    return function(settings) {
        var innerFetch = (settings && settings.fetch) || globalThis.fetch;
        return factory(Object.assign({}, settings, {
            fetch: async function(input, init) {
                var headers = _copyHeaders(init);
                if (!headers.has(_OPENCODE_SESSION_HEADER)) {
                    headers.set(_OPENCODE_SESSION_HEADER, _opencodeSessionIdFromBody(init && init.body));
                }
                return innerFetch(input, Object.assign({}, init, { headers: headers }));
            }
        }));
    };
}
// ---- end local patch --------------------------------------------------------

'''


def patch_text(text: str) -> tuple[str, int]:
    if "_withOpencodeSession" in text:
        raise SystemExit("ERROR: file is already patched (found _withOpencodeSession)")

    found = text.count(DECORATE_ANCHOR)
    if found != 1:
        raise SystemExit(
            f"ERROR: anchor {DECORATE_ANCHOR!r} found {found} times, expected 1 "
            "(upstream changed the emitted shape; inspect the new dist file before patching)"
        )
    text = text.replace(DECORATE_ANCHOR, HELPERS.lstrip("\n") + DECORATE_ANCHOR, 1)

    found = text.count(STANDARD_ANCHOR)
    if found != 1:
        raise SystemExit(
            f"ERROR: anchor {STANDARD_ANCHOR.strip()!r} found {found} times, expected 1"
        )
    text = text.replace(STANDARD_ANCHOR, STANDARD_REPLACEMENT, 1)

    seen: dict[str, int] = {}

    def repl(match: re.Match) -> str:
        fn = match.group("fn")
        seen[fn] = seen.get(fn, 0) + 1
        return (
            f"const provider = _withOpencodeSession(config, "
            f"(0, _{match.group('mod')}.{fn}))({{"
        )

    text, replaced = SITE_RE.subn(repl, text)

    missing = [fn for fn in FACTORY_CALLS if seen.get(fn) != 1]
    if missing:
        raise SystemExit(
            f"ERROR: factory call sites not matched exactly once: {missing} "
            f"(matched: {seen})"
        )

    return text, replaced + 1


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(__doc__)
        return 2

    src, dst = Path(argv[1]), Path(argv[2])
    patched, call_sites = patch_text(src.read_text(encoding="utf-8"))
    dst.write_text(patched, encoding="utf-8")

    print(f"pristine  : {src}")
    print(f"patched   : {dst}")
    print(f"call sites wrapped: {call_sites} (expect 5)")

    if patched.count("x-opencode-session") != 2:
        raise SystemExit("ERROR: expected exactly 2 occurrences of x-opencode-session")

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
