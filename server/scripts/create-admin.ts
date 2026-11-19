/**
 * Development entrypoint for the first-admin CLI. The implementation lives in
 * src/admin-web/create-admin-cli.ts so the compiled production image can run:
 *
 *   node dist/admin-web/create-admin-cli.js --email ... --name ... --role ...
 */
import '../src/admin-web/create-admin-cli.js';
