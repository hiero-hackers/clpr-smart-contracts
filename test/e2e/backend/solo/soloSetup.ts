/// Per-worker setup for Solo e2e tests.
/// Configures extended timeouts so long-running beforeAll hooks
/// (Solo relay funding, contract deployment) don't time out prematurely.
import {expect} from "vitest";

expect.extend({});  // ensure vitest context is loaded

import {vi} from "vitest";

vi.setConfig({
    hookTimeout: 600_000,
    testTimeout: 300_000
});
