import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import test from 'node:test';

test('completed polls release old generations under a 192 MiB heap cap', async () => {
    const { stdout } = await promisify(execFile)(process.execPath, [
        '--expose-gc', '--max-old-space-size=192',
        fileURLToPath(new URL('../scripts/check-live-memory.js', import.meta.url))
    ], { timeout: 30_000 });
    assert.equal(JSON.parse(stdout).retainedGenerations, 1);
});
