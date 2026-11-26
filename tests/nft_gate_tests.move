// SPDX-License-Identifier: 0BSD

// Unit tests for `sealed_storage::nft_gate` (Seal policy: decrypt only with a valid access-gate pass): approval for transferable and soulbound passes, the identity
// namespace, a foreign or exhausted pass, pausing (the default, and the `pause_blocks_decryption` policy), freezing, and the version gate. They build real gates with
// the `access_gate` package this one depends on. Run with `sui move test --build-env testnet`.
//
// Abort codes are referenced by literal in #[expected_failure] because module-private
// constants are not cross-module referenceable in that attribute:
//   E_ID_NOT_NAMESPACED = 1, E_WRONG_GATE = 2, E_EXHAUSTED = 3, E_GATE_PAUSED = 4  (see nft_gate.move).
// Every such test names its `location`: the same small codes exist in `config`, `timelock` and `access_gate`,
// and a location-less test passes on ANY abort with that code.
#[test_only]
/// Unit tests of the NFT-gate Seal policy.
module sealed_storage::nft_gate_tests;

use access_gate::access_gate::{Self, Gate, AdminCap, AccessNFT, SoulboundAccessNFT, GatePolicy, PlatformConfig};
use sealed_storage::config;
use sealed_storage::nft_gate;
use sui::coin;
use sui::sui::SUI;
use sui::test_scenario as ts;

/// The gate creator and `AdminCap` holder in every scenario.
const CREATOR: address = @0xA1;
/// The account that is airdropped a pass and presents it.
const HOLDER: address = @0xB0B;

/// Share a zero-fee PlatformConfig, then create a free gate with `policy` (ready to take next tx).
fun make_gate_with(s: &mut ts::Scenario, soulbound: bool, default_uses: u64, policy: GatePolicy) {
    access_gate::share_platform_config_zero_commission_for_testing(s.ctx());
    s.next_tx(CREATOR);
    let platform = s.take_shared<PlatformConfig>();
    access_gate::create_free_gate(
        &platform, coin::mint_for_testing<SUI>(0, s.ctx()), CREATOR, default_uses, soulbound, false,
        b"".to_string(), b"".to_string(), b"".to_string(), policy, s.ctx(),
    );
    ts::return_shared(platform);
}

/// Create a free gate with the default (unrestricted) policy.
fun make_gate(s: &mut ts::Scenario, soulbound: bool, default_uses: u64) {
    make_gate_with(s, soulbound, default_uses, access_gate::default_gate_policy());
}

/// Airdrop a pass from a free gate (the commission due is 0).
fun grant(s: &mut ts::Scenario, cap: &AdminCap, gate: &Gate, recipient: address) {
    let platform = s.take_shared<PlatformConfig>();
    access_gate::airdrop(cap, gate, &platform, coin::mint_for_testing<SUI>(0, s.ctx()), recipient, s.ctx());
    ts::return_shared(platform);
}

/// access_gate calls that need the shared PlatformConfig (its version gate). A shared object can be
/// taken once per test transaction, so the airdrop and the pause toggles share one borrow.
fun grant_then_set_paused(
    s: &mut ts::Scenario,
    cap: &AdminCap,
    gate: &mut Gate,
    recipient: address,
    states: vector<bool>,
) {
    let platform = s.take_shared<PlatformConfig>();
    access_gate::airdrop(cap, gate, &platform, coin::mint_for_testing<SUI>(0, s.ctx()), recipient, s.ctx());
    states.do!(|paused| access_gate::set_paused(cap, gate, &platform, paused));
    ts::return_shared(platform);
}

/// `access_gate::consume` with the shared `PlatformConfig` (its version gate) and a fixed nonce.
fun consume_t(s: &mut ts::Scenario, nft: AccessNFT, gate: &Gate) {
    let platform = s.take_shared<PlatformConfig>();
    access_gate::consume(nft, gate, &platform, b"nonce_suffix", s.ctx());
    ts::return_shared(platform);
}

/// `access_gate::consume_soulbound` with the shared `PlatformConfig` and a fixed nonce.
fun consume_soulbound_t(s: &mut ts::Scenario, nft: SoulboundAccessNFT, gate: &Gate) {
    let platform = s.take_shared<PlatformConfig>();
    access_gate::consume_soulbound(nft, gate, &platform, b"nonce_suffix", s.ctx());
    ts::return_shared(platform);
}

/// Call a policy with a fresh current-version PolicyConfig (the version gate is tested in config_tests).
fun approve(s: &mut ts::Scenario, id: vector<u8>, gate: &Gate, nft: &AccessNFT) {
    let policy = config::new_for_testing(s.ctx());
    nft_gate::seal_approve(id, &policy, gate, nft);
    config::destroy_for_testing(policy);
}

/// `seal_approve_soulbound` with a fresh current-version `PolicyConfig`.
fun approve_soulbound(s: &mut ts::Scenario, id: vector<u8>, gate: &Gate, nft: &SoulboundAccessNFT) {
    let policy = config::new_for_testing(s.ctx());
    nft_gate::seal_approve_soulbound(id, &policy, gate, nft);
    config::destroy_for_testing(policy);
}

/// A valid identity: the 32-byte gate id followed by a nonce suffix byte.
fun id_for(gate: &Gate): vector<u8> {
    let mut id = object::id_bytes(gate);
    id.push_back(7u8);
    id
}

#[test]
/// A holder of an unlimited transferable pass is approved for an identity namespaced to the gate.
fun approve_unlimited_pass_succeeds() {
    let mut s = ts::begin(CREATOR);
    make_gate(&mut s, false, 0);
    s.next_tx(CREATOR);
    let gate = s.take_shared<Gate>();
    let cap = s.take_from_sender<AdminCap>();
    grant(&mut s, &cap, &gate, HOLDER);
    s.return_to_sender(cap);

    s.next_tx(HOLDER);
    let nft = s.take_from_sender<AccessNFT>();
    approve(&mut s, id_for(&gate), &gate, &nft);
    s.return_to_sender(nft);

    ts::return_shared(gate);
    s.end();
}

#[test]
/// A holder of a soulbound pass is approved by `seal_approve_soulbound`.
fun approve_soulbound_pass_succeeds() {
    let mut s = ts::begin(CREATOR);
    make_gate(&mut s, true, 0);
    s.next_tx(CREATOR);
    let gate = s.take_shared<Gate>();
    let cap = s.take_from_sender<AdminCap>();
    grant(&mut s, &cap, &gate, HOLDER);
    s.return_to_sender(cap);

    s.next_tx(HOLDER);
    let nft = s.take_from_sender<SoulboundAccessNFT>();
    approve_soulbound(&mut s, id_for(&gate), &gate, &nft);
    s.return_to_sender(nft);

    ts::return_shared(gate);
    s.end();
}

// Conformance vector shared bit-for-bit with the client encoder
// (sealed-storage-client/tests/conformance-vectors.json → nftGate). Two properties are pinned:
//  1. The identity layout is [32-byte gate id][nonce] — the first 32 bytes equal object::id_bytes.
//  2. The 32-byte gate id is canonical big-endian right-aligned, so a short id like 0x123 encodes to
//     31 zero bytes then 0x01, 0x23 (matching the client's objectIdBytes('0x123')).
#[test]
/// Pins the identity layout shared with the client encoder: the first 32 bytes equal the gate's object id, canonical big-endian right-aligned (a short id like `0x123` is 31 zero bytes then `01 23`).
fun conformance_gate_id_prefix_layout() {
    let mut s = ts::begin(CREATOR);
    make_gate(&mut s, false, 0);
    s.next_tx(CREATOR);
    let gate = s.take_shared<Gate>();

    // Property 1: id_for prefixes the identity with exactly the 32-byte gate id.
    let id = id_for(&gate);
    let gid = object::id_bytes(&gate);
    let mut i = 0u64;
    while (i < 32) {
        assert!(id[i] == gid[i], 200 + i);
        i = i + 1;
    };

    // Property 2: the framework's object-id byte encoding (the same one `assert_namespaced`
    // compares against via `object::id_bytes`) yields the shared vector's prefix for 0x123:
    // 30 zero bytes then 0x01, 0x23 — i.e. canonical big-endian, right-aligned.
    let expected_0x123 = {
        let mut v: vector<u8> = vector[];
        let mut j = 0u64;
        while (j < 30) { v.push_back(0u8); j = j + 1; };
        v.push_back(0x01);
        v.push_back(0x23);
        v
    };
    assert!(object::id_from_address(@0x123).to_bytes() == expected_0x123, 299);

    ts::return_shared(gate);
    s.end();
}

#[test]
#[expected_failure(abort_code = 2, location = sealed_storage::nft_gate)] // E_WRONG_GATE
/// A pass from gate A presented for gate B (with an identity namespaced to B) aborts with `E_WRONG_GATE` (2).
fun approve_with_foreign_nft_aborts() {
    let mut s = ts::begin(CREATOR);
    make_gate(&mut s, false, 0); // gate A
    make_gate(&mut s, false, 0); // gate B
    s.next_tx(CREATOR);
    // Two gates + two caps exist. Take them in a deterministic order.
    let gate_b = s.take_shared<Gate>();
    let gate_a = s.take_shared<Gate>();
    let cap_a = s.take_from_sender<AdminCap>();
    // cap_a authorises exactly one of the gates; airdrop from whichever it matches.
    if (access_gate::admin_cap_gate_id(&cap_a) == object::id(&gate_a)) {
        grant(&mut s, &cap_a, &gate_a, HOLDER);
    } else {
        grant(&mut s, &cap_a, &gate_b, HOLDER);
    };
    s.return_to_sender(cap_a);

    s.next_tx(HOLDER);
    let nft = s.take_from_sender<AccessNFT>();
    // Namespace the id to whichever gate the NFT is NOT valid for, so the namespace check
    // passes and the is_valid_for check is what aborts.
    let (target, other) = if (access_gate::is_valid_for(&nft, &gate_a)) {
        (&gate_b, &gate_a)
    } else {
        (&gate_a, &gate_b)
    };
    let _ = other;
    approve(&mut s, id_for(target), target, &nft); // aborts E_WRONG_GATE

    s.return_to_sender(nft);
    ts::return_shared(gate_a);
    ts::return_shared(gate_b);
    s.end();
}

#[test]
#[expected_failure(abort_code = 1, location = sealed_storage::nft_gate)] // E_ID_NOT_NAMESPACED
/// An identity not namespaced to the gate aborts with `E_ID_NOT_NAMESPACED` (1): a pass for one gate cannot decrypt content sealed for another.
fun approve_with_wrong_namespace_aborts() {
    let mut s = ts::begin(CREATOR);
    make_gate(&mut s, false, 0);
    s.next_tx(CREATOR);
    let gate = s.take_shared<Gate>();
    let cap = s.take_from_sender<AdminCap>();
    grant(&mut s, &cap, &gate, HOLDER);
    s.return_to_sender(cap);

    s.next_tx(HOLDER);
    let nft = s.take_from_sender<AccessNFT>();
    // 32 zero bytes + suffix — not this gate's id.
    let mut bad: vector<u8> = vector[];
    let mut i = 0u64;
    while (i < 33) { bad.push_back(0u8); i = i + 1; };
    approve(&mut s, bad, &gate, &nft); // aborts E_ID_NOT_NAMESPACED

    s.return_to_sender(nft);
    ts::return_shared(gate);
    s.end();
}

// Boundary: an id with exactly 32 bytes (no nonce suffix) passes `assert_namespaced` so long
// as the bytes match the gate id — the minimum valid identity length.
#[test]
/// An identity of exactly 32 bytes (the gate id, no nonce suffix) is valid.
fun approve_with_exact_32_byte_id_succeeds() {
    let mut s = ts::begin(CREATOR);
    make_gate(&mut s, false, 0);
    s.next_tx(CREATOR);
    let gate = s.take_shared<Gate>();
    let cap = s.take_from_sender<AdminCap>();
    grant(&mut s, &cap, &gate, HOLDER);
    s.return_to_sender(cap);

    s.next_tx(HOLDER);
    let nft = s.take_from_sender<AccessNFT>();
    // Exactly 32 bytes = just the gate id, no trailing nonce.
    let id = object::id_bytes(&gate);
    assert!(id.length() == 32, 400);
    approve(&mut s, id, &gate, &nft);
    s.return_to_sender(nft);

    ts::return_shared(gate);
    s.end();
}

// Boundary: an id shorter than 32 bytes aborts with E_ID_NOT_NAMESPACED immediately
// (does not read past bounds or produce a silent gate-mismatch).
#[test]
#[expected_failure(abort_code = 1, location = sealed_storage::nft_gate)] // E_ID_NOT_NAMESPACED
/// An identity shorter than 32 bytes aborts with `E_ID_NOT_NAMESPACED` (1) without reading past its end.
fun approve_with_7_byte_id_aborts() {
    let mut s = ts::begin(CREATOR);
    make_gate(&mut s, false, 0);
    s.next_tx(CREATOR);
    let gate = s.take_shared<Gate>();
    let cap = s.take_from_sender<AdminCap>();
    grant(&mut s, &cap, &gate, HOLDER);
    s.return_to_sender(cap);

    s.next_tx(HOLDER);
    let nft = s.take_from_sender<AccessNFT>();
    let bad: vector<u8> = vector[0, 1, 2, 3, 4, 5, 6]; // 7 bytes < 32
    approve(&mut s, bad, &gate, &nft); // aborts E_ID_NOT_NAMESPACED

    s.return_to_sender(nft);
    ts::return_shared(gate);
    s.end();
}

#[test]
#[expected_failure(abort_code = 3, location = sealed_storage::nft_gate)] // E_EXHAUSTED
/// A single-use pass with zero uses left aborts with `E_EXHAUSTED` (3).
fun approve_with_exhausted_pass_aborts() {
    let mut s = ts::begin(CREATOR);
    make_gate(&mut s, false, 1); // single-use, 1 use, auto_burn = false → returns 0-use receipt
    s.next_tx(CREATOR);
    let gate = s.take_shared<Gate>();
    let cap = s.take_from_sender<AdminCap>();
    grant(&mut s, &cap, &gate, HOLDER);
    s.return_to_sender(cap);

    s.next_tx(HOLDER);
    let nft = s.take_from_sender<AccessNFT>();
    consume_t(&mut s, nft, &gate); // decrements 1 → 0, returns receipt

    s.next_tx(HOLDER);
    let spent = s.take_from_sender<AccessNFT>();
    approve(&mut s, id_for(&gate), &gate, &spent); // aborts E_EXHAUSTED

    s.return_to_sender(spent);
    ts::return_shared(gate);
    s.end();
}

// ── Soulbound variants of the abort paths ────────────────────────────────────────

#[test]
#[expected_failure(abort_code = 2, location = sealed_storage::nft_gate)] // E_WRONG_GATE
/// Soulbound counterpart of the foreign-pass abort: `E_WRONG_GATE` (2).
fun approve_soulbound_with_foreign_nft_aborts() {
    let mut s = ts::begin(CREATOR);
    make_gate(&mut s, true, 0);
    s.next_tx(CREATOR);
    let gate_a = s.take_shared<Gate>();
    let cap = s.take_from_sender<AdminCap>();
    grant(&mut s, &cap, &gate_a, HOLDER);
    s.return_to_sender(cap);
    ts::return_shared(gate_a);

    s.next_tx(CREATOR);
    make_gate(&mut s, true, 0); // gate B (newest shared)
    s.next_tx(HOLDER);
    let gate_b = s.take_shared<Gate>();
    let nft = s.take_from_sender<SoulboundAccessNFT>();
    approve_soulbound(&mut s, id_for(&gate_b), &gate_b, &nft); // NFT is gate A's
    s.return_to_sender(nft);
    ts::return_shared(gate_b);
    s.end();
}

#[test]
#[expected_failure(abort_code = 3, location = sealed_storage::nft_gate)] // E_EXHAUSTED
/// Soulbound counterpart of the exhausted-pass abort: `E_EXHAUSTED` (3).
fun approve_soulbound_with_exhausted_pass_aborts() {
    let mut s = ts::begin(CREATOR);
    make_gate(&mut s, true, 1);
    s.next_tx(CREATOR);
    let gate = s.take_shared<Gate>();
    let cap = s.take_from_sender<AdminCap>();
    grant(&mut s, &cap, &gate, HOLDER);
    s.return_to_sender(cap);

    s.next_tx(HOLDER);
    let nft = s.take_from_sender<SoulboundAccessNFT>();
    consume_soulbound_t(&mut s, nft, &gate);
    s.next_tx(HOLDER);
    let spent = s.take_from_sender<SoulboundAccessNFT>();
    approve_soulbound(&mut s, id_for(&gate), &gate, &spent);
    s.return_to_sender(spent);
    ts::return_shared(gate);
    s.end();
}

#[test]
/// Membership semantics: approving a single-use pass twice leaves its uses unchanged (`seal_approve` is side-effect free).
fun approve_single_use_pass_with_uses_left_succeeds_without_consuming() {
    // Membership semantics: approving does not spend a use (seal_approve is side-effect free).
    let mut s = ts::begin(CREATOR);
    make_gate(&mut s, false, 2);
    s.next_tx(CREATOR);
    let gate = s.take_shared<Gate>();
    let cap = s.take_from_sender<AdminCap>();
    grant(&mut s, &cap, &gate, HOLDER);
    s.return_to_sender(cap);

    s.next_tx(HOLDER);
    let nft = s.take_from_sender<AccessNFT>();
    approve(&mut s, id_for(&gate), &gate, &nft);
    approve(&mut s, id_for(&gate), &gate, &nft);
    assert!(access_gate::uses_remaining(&nft) == option::some(2), 0);
    s.return_to_sender(nft);
    ts::return_shared(gate);
    s.end();
}

#[test]
/// Documents the default (audit OQ7, decided 2026-09-28): pausing a gate stops purchases, not decryption.
fun approve_on_paused_gate_still_succeeds() {
    // Documents current behaviour (audit OQ7, decided 2026-09-28): pausing a gate stops purchases, not decryption.
    let mut s = ts::begin(CREATOR);
    make_gate(&mut s, false, 0);
    s.next_tx(CREATOR);
    let mut gate = s.take_shared<Gate>();
    let cap = s.take_from_sender<AdminCap>();
    grant_then_set_paused(&mut s, &cap, &mut gate, HOLDER, vector[true]);
    s.return_to_sender(cap);

    s.next_tx(HOLDER);
    let nft = s.take_from_sender<AccessNFT>();
    approve(&mut s, id_for(&gate), &gate, &nft);
    s.return_to_sender(nft);
    ts::return_shared(gate);
    s.end();
}

// ── Gate policy: pause_blocks_decryption ─────────────────────────────────────────

/// Create a free gate whose policy blocks decryption while paused when `pause_blocks_decryption` is true (it must then also require the gate unpaused to freeze, which `access_gate` enforces).
fun make_policy_gate(s: &mut ts::Scenario, pause_blocks_decryption: bool) {
    // A policy that blocks decryption while paused must also forbid freezing while paused (access_gate enforces it).
    make_gate_with(s, false, 0, access_gate::new_gate_policy(pause_blocks_decryption, false, pause_blocks_decryption, false));
}

/// Airdrop a pass, pause the gate, then approve as the holder.
fun approve_while_paused(pause_blocks_decryption: bool) {
    let mut s = ts::begin(CREATOR);
    make_policy_gate(&mut s, pause_blocks_decryption);
    s.next_tx(CREATOR);
    let mut gate = s.take_shared<Gate>();
    let cap = s.take_from_sender<AdminCap>();
    grant_then_set_paused(&mut s, &cap, &mut gate, HOLDER, vector[true]);
    s.return_to_sender(cap);

    s.next_tx(HOLDER);
    let nft = s.take_from_sender<AccessNFT>();
    approve(&mut s, id_for(&gate), &gate, &nft);
    s.return_to_sender(nft);
    ts::return_shared(gate);
    s.end();
}

#[test]
#[expected_failure(abort_code = 4, location = sealed_storage::nft_gate)] // E_GATE_PAUSED
/// With `pause_blocks_decryption`, approving on a paused gate aborts with `E_GATE_PAUSED` (4).
fun approve_denied_while_paused_when_policy_blocks_decryption() {
    approve_while_paused(true);
}

#[test]
/// Without the policy flag, approving on a paused gate succeeds.
fun approve_allowed_while_paused_without_policy() {
    approve_while_paused(false);
}

#[test]
/// With `pause_blocks_decryption`, approval works again once the gate is unpaused.
fun approve_resumes_after_unpause_when_policy_blocks_decryption() {
    let mut s = ts::begin(CREATOR);
    make_policy_gate(&mut s, true);
    s.next_tx(CREATOR);
    let mut gate = s.take_shared<Gate>();
    let cap = s.take_from_sender<AdminCap>();
    grant_then_set_paused(&mut s, &cap, &mut gate, HOLDER, vector[true, false]);
    s.return_to_sender(cap);

    s.next_tx(HOLDER);
    let nft = s.take_from_sender<AccessNFT>();
    approve(&mut s, id_for(&gate), &gate, &nft);
    s.return_to_sender(nft);
    ts::return_shared(gate);
    s.end();
}


/// Pause the newest gate (`cap` is its AdminCap) with the newest PlatformConfig.
fun pause(s: &mut ts::Scenario, cap: &AdminCap, gate: &mut Gate) {
    let platform = s.take_shared<PlatformConfig>();
    access_gate::set_paused(cap, gate, &platform, true);
    ts::return_shared(platform);
}

// Check order: a paused policy gate presented with a foreign pass aborts E_GATE_PAUSED (4), not E_WRONG_GATE (2).
#[test]
#[expected_failure(abort_code = 4, location = sealed_storage::nft_gate)] // E_GATE_PAUSED, before the pass is checked
/// The check order: a paused policy gate presented with a foreign pass aborts `E_GATE_PAUSED` (4), not `E_WRONG_GATE` (2).
fun paused_policy_gate_with_foreign_pass_aborts_paused_first() {
    let mut s = ts::begin(CREATOR);
    make_gate(&mut s, false, 0); // gate A: the pass comes from here
    s.next_tx(CREATOR);
    let gate_a = s.take_shared<Gate>();
    let cap_a = s.take_from_sender<AdminCap>();
    grant(&mut s, &cap_a, &gate_a, HOLDER);
    s.return_to_sender(cap_a);
    ts::return_shared(gate_a);

    s.next_tx(CREATOR);
    make_policy_gate(&mut s, true); // gate B: pause blocks decryption
    s.next_tx(CREATOR);
    let mut gate_b = s.take_shared<Gate>();
    let cap_b = s.take_from_sender<AdminCap>();
    pause(&mut s, &cap_b, &mut gate_b);
    s.return_to_sender(cap_b);

    s.next_tx(HOLDER);
    let nft = s.take_from_sender<AccessNFT>(); // gate A's pass
    approve(&mut s, id_for(&gate_b), &gate_b, &nft);
    s.return_to_sender(nft);
    ts::return_shared(gate_b);
    s.end();
}

// Freezing a gate never affects decryption: a pass still approves after `make_gate_immutable`.
#[test]
/// Freezing a gate never affects decryption: a pass still approves after `make_gate_immutable`.
fun approve_succeeds_after_the_gate_is_frozen() {
    let mut s = ts::begin(CREATOR);
    make_policy_gate(&mut s, true);
    s.next_tx(CREATOR);
    let mut gate = s.take_shared<Gate>();
    let cap = s.take_from_sender<AdminCap>();
    let platform = s.take_shared<PlatformConfig>();
    access_gate::airdrop(&cap, &gate, &platform, coin::mint_for_testing<SUI>(0, s.ctx()), HOLDER, s.ctx());
    access_gate::make_gate_immutable(cap, &mut gate, &platform, s.ctx()); // consumes the cap; gate is unpaused
    ts::return_shared(platform);
    assert!(gate.gate_is_frozen(), 0);

    s.next_tx(HOLDER);
    let nft = s.take_from_sender<AccessNFT>();
    approve(&mut s, id_for(&gate), &gate, &nft);
    s.return_to_sender(nft);
    ts::return_shared(gate);
    s.end();
}

// F21: a gate whose pause blocks decryption cannot be frozen while paused (so its content can never be made
// permanently undecryptable by pausing and then freezing). access_gate aborts E_FREEZE_WHILE_PAUSED (10).
#[test]
#[expected_failure(abort_code = 10, location = access_gate)] // E_FREEZE_WHILE_PAUSED
/// F21: a gate whose pause blocks decryption cannot be frozen while paused (`access_gate` aborts `E_FREEZE_WHILE_PAUSED`, 10), so its content cannot be made permanently undecryptable.
fun a_blocking_policy_gate_cannot_be_frozen_while_paused() {
    let mut s = ts::begin(CREATOR);
    make_policy_gate(&mut s, true);
    s.next_tx(CREATOR);
    let mut gate = s.take_shared<Gate>();
    let cap = s.take_from_sender<AdminCap>();
    let platform = s.take_shared<PlatformConfig>();
    access_gate::set_paused(&cap, &mut gate, &platform, true);
    access_gate::make_gate_immutable(cap, &mut gate, &platform, s.ctx());
    ts::return_shared(platform);
    ts::return_shared(gate);
    s.end();
}

// F16 (known property): a holder can freeze a TRANSFERABLE pass (`AccessNFT` has `store`), after which it is an
// immutable object anyone can present, and the policy approves it. Sealed Storage gates should be soulbound.
#[test]
/// F16, a known property: a holder can freeze a transferable pass, after which it is an immutable object anyone can present and the policy approves it. Sealed Storage gates should be soulbound.
fun a_frozen_transferable_pass_still_approves_for_anyone() {
    let mut s = ts::begin(CREATOR);
    make_gate(&mut s, false, 0);
    s.next_tx(CREATOR);
    let gate = s.take_shared<Gate>();
    let cap = s.take_from_sender<AdminCap>();
    grant(&mut s, &cap, &gate, HOLDER);
    s.return_to_sender(cap);
    ts::return_shared(gate);

    s.next_tx(HOLDER);
    let nft = s.take_from_sender<AccessNFT>();
    transfer::public_freeze_object(nft);

    s.next_tx(@0xBAD); // a stranger who never owned the pass
    let gate = s.take_shared<Gate>();
    let frozen = s.take_immutable<AccessNFT>();
    approve(&mut s, id_for(&gate), &gate, &frozen);
    ts::return_immutable(frozen);
    ts::return_shared(gate);
    s.end();
}

// A soulbound pass cannot be frozen or shared by its holder: the type has no `store`, so only this
// package's functions can move it. (There is nothing to call here; the compiler is the test: this module
// would not build if `transfer::public_freeze_object(soulbound)` type-checked.)

// ── Version gate ─────────────────────────────────────────────────────────────────

/// A valid pass that would be approved at the current version, checked against another version.
fun approve_at_version(soulbound: bool, version: u64) {
    let mut s = ts::begin(CREATOR);
    make_gate(&mut s, soulbound, 0);
    s.next_tx(CREATOR);
    let gate = s.take_shared<Gate>();
    let cap = s.take_from_sender<AdminCap>();
    grant(&mut s, &cap, &gate, HOLDER);
    s.return_to_sender(cap);

    s.next_tx(HOLDER);
    let mut policy = config::new_for_testing(s.ctx());
    config::set_version_for_testing(&mut policy, version);
    if (soulbound) {
        let nft = s.take_from_sender<SoulboundAccessNFT>();
        nft_gate::seal_approve_soulbound(id_for(&gate), &policy, &gate, &nft);
        s.return_to_sender(nft);
    } else {
        let nft = s.take_from_sender<AccessNFT>();
        nft_gate::seal_approve(id_for(&gate), &policy, &gate, &nft);
        s.return_to_sender(nft);
    };
    config::destroy_for_testing(policy);
    ts::return_shared(gate);
    s.end();
}

#[test]
/// Control for the version tests: the same pass is approved at the current version.
fun approve_at_current_version_succeeds() {
    approve_at_version(false, config::package_version());
}

#[test]
#[expected_failure(abort_code = 1, location = sealed_storage::config)] // E_WRONG_VERSION
/// With the `PolicyConfig` at another version, `seal_approve` aborts with `config::E_WRONG_VERSION` (1).
fun wrong_version_blocks_seal_approve() {
    approve_at_version(false, config::package_version() + 1);
}

#[test]
#[expected_failure(abort_code = 1, location = sealed_storage::config)] // E_WRONG_VERSION
/// With the `PolicyConfig` at another version, `seal_approve_soulbound` aborts with `config::E_WRONG_VERSION` (1).
fun wrong_version_blocks_seal_approve_soulbound() {
    approve_at_version(true, 0);
}
