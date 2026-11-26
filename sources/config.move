// SPDX-License-Identifier: 0BSD

/// Package-wide version gate for every Seal policy and for `sealed_content::publish`.
///
/// Older package versions stay callable on-chain forever. If an upgrade fixes a policy, a key server
/// could still be asked to evaluate the old `seal_approve*`. Every policy therefore takes the shared
/// `PolicyConfig` and aborts unless its `version` equals this package version's `VERSION`. An upgrade
/// bumps `VERSION`; the `PolicyAdminCap` holder then calls `migrate`, which retires every older
/// version at once (Sui upgrade guide: versioned shared objects; Seal: `seal_approve*` as non-public
/// `entry` functions).
module sealed_storage::config;

use sui::event;

/// The shared `PolicyConfig` names a different package version than the code being called.
const E_WRONG_VERSION: u64 = 1;
/// `migrate` only moves forward: the config is already at (or past) this package's version.
const E_NOT_UPGRADE: u64 = 2;

/// This package version. Bump it in every upgrade that must retire the previous code.
const VERSION: u64 = 1;

/// The one shared version object, created by `init`.
public struct PolicyConfig has key {
    id: UID,
    version: u64,
}

/// Authorises `migrate`. Held by the custody multisig (CUSTODY.md).
public struct PolicyAdminCap has key, store {
    id: UID,
}

/// Emitted by `migrate`.
public struct PolicyConfigMigratedEvent has copy, drop {
    from_version: u64,
    to_version: u64,
}

/// Called once on publish: shares the `PolicyConfig` at this package version and gives the `PolicyAdminCap` to the publisher.
fun init(ctx: &mut TxContext) {
    transfer::share_object(PolicyConfig { id: object::new(ctx), version: VERSION });
    transfer::public_transfer(PolicyAdminCap { id: object::new(ctx) }, ctx.sender());
}

/// Abort with `E_WRONG_VERSION` unless `config` names this package version.
public(package) fun check_version(config: &PolicyConfig) {
    assert!(config.version == VERSION, E_WRONG_VERSION);
}

/// Move the shared config to this package version, retiring every older version.
public fun migrate(_cap: &PolicyAdminCap, config: &mut PolicyConfig) {
    assert!(config.version < VERSION, E_NOT_UPGRADE);
    let from_version = config.version;
    config.version = VERSION;
    event::emit(PolicyConfigMigratedEvent { from_version, to_version: VERSION });
}

// ── Views ────────────────────────────────────────────────────────────────────────
/// The package version the shared config currently names (the only one allowed to act).
public fun version(config: &PolicyConfig): u64 { config.version }
/// This package's `VERSION`.
public fun package_version(): u64 { VERSION }

// ── Test-only ────────────────────────────────────────────────────────────────────
#[test_only]
/// Run `init` in a test scenario, as publish does.
public fun init_for_testing(ctx: &mut TxContext) { init(ctx) }

#[test_only]
/// A fresh, unshared `PolicyConfig` at the current version, for tests that call a policy directly (destroy it with `destroy_for_testing`).
public fun new_for_testing(ctx: &mut TxContext): PolicyConfig {
    PolicyConfig { id: object::new(ctx), version: VERSION }
}

#[test_only]
/// Force the config's version (simulates a config left at an older version, or migrated past this package).
public fun set_version_for_testing(config: &mut PolicyConfig, version: u64) {
    config.version = version;
}

#[test_only]
/// Delete a `PolicyConfig` made by `new_for_testing`.
public fun destroy_for_testing(config: PolicyConfig) {
    let PolicyConfig { id, version: _ } = config;
    id.delete();
}
