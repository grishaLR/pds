"use strict";
/**
 * recover-actor.js — Re-initialize an actor store for an existing DID.
 *
 * Use when the account row exists in account.sqlite but the actor directory
 * (store.sqlite + key) is missing. This preserves the DID so followers are kept.
 *
 * Usage (on the PDS machine):
 *   node recover-actor.js did:plc:qakelcnspwr3a7oow7x666ad
 *
 * What it does:
 *   1. Boots the PDS context (same as normal startup)
 *   2. Generates a new signing keypair
 *   3. Creates the actor directory + store.sqlite + key file
 *   4. Signs an initial empty repo commit
 *   5. Updates the repo root in account manager
 *   6. Rotates the signing key in PLC directory (using the PDS rotation key)
 *   7. Sequences identity + account + commit events
 */

const {
  PDS,
  envToCfg,
  envToSecrets,
  readEnv,
} = require("@atproto/pds");
const crypto = require("/app/node_modules/.pnpm/@atproto+crypto@0.4.5/node_modules/@atproto/crypto");
const pkg = require("@atproto/pds/package.json");

const main = async () => {
  const did = process.argv[2];
  if (!did || !did.startsWith("did:")) {
    console.error("Usage: node recover-actor.js <did>");
    process.exit(1);
  }

  console.log(`[recover] Booting PDS context...`);
  const env = readEnv();
  env.version ||= pkg.version;
  const cfg = envToCfg(env);
  const secrets = envToSecrets(env);
  const pds = await PDS.create(cfg, secrets);

  const ctx = pds.ctx;

  // Verify the account exists
  const account = await ctx.accountManager.getAccount(did);
  if (!account) {
    console.error(`[recover] No account found for ${did}`);
    await pds.destroy();
    process.exit(1);
  }
  console.log(`[recover] Found account: ${did} (handle: ${account.handle})`);

  // Check if actor store already exists
  try {
    await ctx.actorStore.read(did, async () => {});
    console.error(`[recover] Actor store already exists for ${did} — nothing to recover`);
    await pds.destroy();
    process.exit(1);
  } catch {
    console.log(`[recover] Confirmed: actor store is missing. Proceeding with recovery.`);
  }

  // Step 1: Create a new signing keypair directly
  console.log(`[recover] Generating new signing keypair...`);
  const signingKey = await crypto.Secp256k1Keypair.create({ exportable: true });
  const signingKeyDid = signingKey.did();
  console.log(`[recover] New signing key DID: ${signingKeyDid}`);

  // Step 2: Create actor store (directory + store.sqlite + key file)
  console.log(`[recover] Creating actor store...`);
  await ctx.actorStore.create(did, signingKey);

  // Step 3: Create empty repo with initial commit
  console.log(`[recover] Creating empty repo...`);
  const commit = await ctx.actorStore.transact(did, (actorTxn) =>
    actorTxn.repo.createRepo([])
  );
  console.log(`[recover] Repo created — cid: ${commit.cid}, rev: ${commit.rev}`);

  // Step 4: Update repo root in account manager
  await ctx.accountManager.updateRepoRoot(did, commit.cid, commit.rev);
  console.log(`[recover] Repo root updated in account manager`);

  // Step 5: Rotate signing key in PLC
  console.log(`[recover] Updating PLC with new signing key...`);
  try {
    await ctx.plcClient.updateAtprotoKey(did, ctx.plcRotationKey, signingKey.did());
    console.log(`[recover] PLC updated successfully`);
  } catch (err) {
    console.error(`[recover] WARNING: PLC update failed:`, err.message);
    console.error(`[recover] The actor store was created but PLC still has the old key.`);
    console.error(`[recover] You may need to run the rotate-keys script manually.`);
  }

  // Step 6: Sequence events so the relay picks up the change
  console.log(`[recover] Sequencing identity + account events...`);
  await ctx.sequencer.sequenceIdentityEvt(did, account.handle);
  await ctx.sequencer.sequenceCommit(did, commit);
  console.log(`[recover] Events sequenced`);

  // Clean up any leftover reserved keypairs
  await ctx.actorStore.clearReservedKeypair(signingKeyDid, did).catch(() => {});

  console.log(`\n[recover] ✓ Recovery complete for ${did}`);
  console.log(`[recover]   Handle: ${account.handle}`);
  console.log(`[recover]   New signing key: ${signingKeyDid}`);
  console.log(`[recover]   Repo: empty (posts/follows will need to be re-created)`);
  console.log(`[recover]   Followers: preserved (they follow the DID, not the repo)`);

  await pds.destroy();
  process.exit(0);
};

main().catch((err) => {
  console.error("[recover] Fatal error:", err);
  process.exit(1);
});
