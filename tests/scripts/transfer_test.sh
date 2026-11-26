#!/usr/bin/env bash
# Offline tests for scripts/transfer-authority.sh. A stub `sui` on PATH answers from per-object state files and
# records every transfer, so no network or chain is needed; the real-chain rehearsals are in CUSTODY.md ("Rehearsal").
# Covers the multisig re-derivation (FU-0083): missing inputs, a wrong address, bad weights; the on-chain owner checks;
# the two typed confirmations (YES, then UPGRADECAP); a partial failure and the refusal of a re-run.
# Run: bash tests/scripts/transfer_test.sh
# No `-e`: a failing command is a test result to count, not a reason to stop; `-u` and `pipefail` still catch typos and broken pipes.
set -uo pipefail

# This file's directory and the repository root, so the tests run from any working directory.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$HERE/../.." && pwd)"
# A scratch directory for the stub CLI and the copied scripts; removed on exit (the `:?` stops an empty variable turning the cleanup into `rm -rf /`).
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK:?}"' EXIT
# The scripts under test parse the CLI's JSON with jq, so the tests need it too.
command -v jq >/dev/null || { echo "jq is required"; exit 1; }

# The number of failed checks; the script exits 1 at the end if it is not 0.
FAILS=0
# ok <name>: report a passed check.
ok()   { printf 'ok    %s\n' "$1"; }
# fail <message>: report a failed check and count it.
fail() { printf 'FAIL  %s\n' "$1"; FAILS=$((FAILS + 1)); }
# expect <name> <expected-exit> <output-substring> -- <command...>: run the command and require both its exit code and a substring of its combined output.
expect() { # expect <name> <expected-exit> <output-substring> -- cmd...
  local name="$1" want="$2" needle="$3" out rc; shift 4
  out="$("$@" 2>&1)"; rc=$?
  if [ "$rc" = "$want" ] && [[ "$out" == *"$needle"* ]]; then ok "$name"; else fail "$name (exit $rc, wanted $want, needle '$needle'): $out"; fi
}
# count <name> <wanted>: check how many transfers the stub recorded (it appends one line per transfer to state/transfers.log).
count() { # count <name> <wanted> -- the number of transfers the stub recorded
  local got; got="$(wc -l < "$D/state/transfers.log" | tr -d ' ')"
  if [ "$got" = "$2" ]; then ok "$1"; else fail "$1: $got transfer(s), wanted $2"; fi
}

# hex <digit>: 64 copies of the digit, to make a fixed 64-hex-digit id.
hex() { local out=''; while [ "${#out}" -lt 64 ]; do out+="$1"; done; printf '%s' "$out"; }
# Fixed ids: PKG the package, ME the deploy key, MS the multisig, OTHER a stranger, ADMIN the PolicyAdminCap, CAP the UpgradeCap; FW the framework address.
# PK1 and PK2 are two real-format base64 public keys (flag byte first); the stub never checks them, it answers the derivation from STUB_DERIVED.
PKG=0x$(hex 1); ME=0x$(hex 2); MS=0x$(hex a); OTHER=0x$(hex 3)
ADMIN=0x$(hex b); CAP=0x$(hex f)
FW=0x0000000000000000000000000000000000000000000000000000000000000002
PK1="AOrJGhZVCDtnjRQvbvv6EwikJo2TJlJ/amfJdb50KeRZ"; PK2="AJ5cf32Ne6OJsy0P4JpbZ3KQnuenq48WtZCAzf3+oxEt"

# The scratch checkout: copies of the two scripts under test, a stub `sui` on PATH, per-object state files, and an empty deployments.json.
D="$WORK/repo"
mkdir -p "$D/scripts" "$D/bin" "$D/state"
cp "$SRC/scripts/multisig-address.sh" "$D/scripts/"
cp "$SRC/scripts/transfer-authority.sh" "$D/scripts/"
echo "{}" > "$D/deployments.json"

# The stub CLI: `client object` answers from state/<id>.{type,owner,pkg}; `client transfer` records the transfer and changes the owner (or fails for STUB_FAIL_ON);
# `keytool multi-sig-address` answers STUB_DERIVED. Anything else exits 99, so an unexpected call fails the test.
cat > "$D/bin/sui" <<'STUB'
#!/usr/bin/env bash
S="$STUB_STATE"
case "$1 $2" in
  "--version "*) echo "sui 1.81.0-stub" ;;
  "client active-env") echo localnet ;;
  "client active-address") echo "$STUB_ME" ;;
  "client object")
    id="$3"
    [ -f "$S/$id.type" ] || exit 1
    jq -n --arg t "$(cat "$S/$id.type")" --arg o "$(cat "$S/$id.owner")" --arg p "$(cat "$S/$id.pkg" 2>/dev/null)" \
      '{objType:$t, owner:{AddressOwner:$o}, content:(if $p=="" then {} else {package:$p} end)}' ;;
  "client transfer")
    id=""; to=""
    while [ $# -gt 0 ]; do case "$1" in --object-id) id="$2"; shift 2 ;; --to) to="$2"; shift 2 ;; *) shift ;; esac; done
    [ "$id" = "${STUB_FAIL_ON:-}" ] && { echo "stub: transfer rejected" >&2; exit 1; }
    echo "$id $to" >> "$S/transfers.log"; printf '%s' "$to" > "$S/$id.owner"
    echo '{"digest":"stubdigest"}' ;;
  "keytool multi-sig-address") jq -n --arg a "$STUB_DERIVED" '{multisigAddress:$a}' ;;
  *) echo "stub sui: unexpected: $*" >&2; exit 99 ;;
esac
STUB
chmod +x "$D/bin/sui"

# seed: (re)create the on-chain state, with the PolicyAdminCap and the UpgradeCap owned by the deploy key.
seed() { # (re)create the on-chain state: every authority object owned by the deploy key
  rm -rf "$D/state"; mkdir -p "$D/state"; : > "$D/state/transfers.log"
  # put <id> <type> [<package>]: one object's state files, owned by ME.
  put() { printf '%s' "$2" > "$D/state/$1.type"; printf '%s' "$ME" > "$D/state/$1.owner"; [ -z "${3:-}" ] || printf '%s' "$3" > "$D/state/$1.pkg"; }
  put "$ADMIN" "$PKG::config::PolicyAdminCap"
  put "$CAP" "$FW::package::UpgradeCap" "$PKG"
}

# run <stdin> [script args]: the transfer script on localnet with the multisig inputs from the caller's variables (ADDR, PKS, WEIGHTS, THRESHOLD, DRY_RUN) and
# the typed confirmations on stdin.
run() { # run <stdin> [script args]; the multisig inputs come from the environment of the caller
  local stdin="$1"; shift
  printf '%b' "$stdin" | env PATH="$D/bin:$PATH" NETWORK=localnet PACKAGE_ID="$PKG" ORIGINAL_ID="$PKG" POLICY_ADMIN_CAP_ID="$ADMIN" UPGRADE_CAP_ID="$CAP" STUB_STATE="$D/state" STUB_ME="$ME" \
    STUB_DERIVED="${STUB_DERIVED-$MS}" STUB_FAIL_ON="${STUB_FAIL_ON-}" MULTISIG_ADDRESS="${ADDR-$MS}" \
    MULTISIG_PKS="${PKS-$PK1 $PK2}" MULTISIG_WEIGHTS="${WEIGHTS-1 1}" MULTISIG_THRESHOLD="${THRESHOLD-2}" DRY_RUN="${DRY_RUN-1}" \
    bash "$D/scripts/transfer-authority.sh" "$@"
}

# Refusals before anything is sent: missing or inconsistent multisig inputs, a wrong derived address, an object not owned by the deploy key.
seed
PKS="" expect "no MULTISIG_PKS: refused" 1 "MULTISIG_PKS" -- run ""
WEIGHTS="1" expect "keys and weights differ in number: refused" 1 "2 keys but 1 weights" -- run ""
THRESHOLD=3 expect "a threshold above the total weight: refused" 1 "must be between 1 and the total weight 2" -- run ""
THRESHOLD=abc expect "a threshold that is not a number: refused" 1 "MULTISIG_THRESHOLD must be a number" -- run ""
STUB_DERIVED="$OTHER" expect "an address that is not the multisig of the given keys: refused" 1 "is not the multisig of the given keys, weights and threshold" -- run ""
count "...and nothing was sent" 0
STUB_DERIVED="" expect "the CLI cannot derive an address: refused" 1 "could not derive a multisig address" -- run ""
expect "the right address: the dry run goes through" 0 "Dry run — re-run with DRY_RUN=0" -- run ""
count "...and a dry run sends nothing" 0

seed; printf '%s' "$OTHER" > "$D/state/$ADMIN.owner"
expect "an object owned by someone else: refused before anything is sent" 1 "is owned by" -- run ""
count "...none sent" 0

# Execution: the confirmation word, the PolicyAdminCap, then the UpgradeCap only with its own flag and confirmation.
seed
DRY_RUN=0 expect "wrong confirmation word aborts" 1 "Aborted" -- run "no\n"
count "...none sent after a refused confirmation" 0
DRY_RUN=0 expect "YES transfers the PolicyAdminCap and verifies the new owner" 0 "is now owned by the multisig" -- run "YES\n"
count "...one transfer" 1
if grep -q "$CAP" "$D/state/transfers.log"; then fail "the UpgradeCap was sent without --include-upgrade-cap"; else ok "the UpgradeCap stays put without --include-upgrade-cap"; fi

seed
DRY_RUN=0 expect "--include-upgrade-cap needs its own UPGRADECAP confirmation after YES" 1 "Aborted (nothing sent)" -- run "YES\nYES\n" --include-upgrade-cap
count "...none sent" 0
DRY_RUN=0 expect "YES then UPGRADECAP sends both" 0 "is now owned by the multisig" -- run "YES\nUPGRADECAP\n" --include-upgrade-cap
count "...two transfers" 2

# A partial failure: the UpgradeCap's transfer fails after the PolicyAdminCap was sent, and a re-run refuses what is already transferred.
seed
DRY_RUN=0 STUB_FAIL_ON="$CAP" expect "a failing transfer stops with recovery advice" 1 "Recovery:" -- run "YES\nUPGRADECAP\n" --include-upgrade-cap
count "...the object before it was sent" 1
DRY_RUN=0 expect "a re-run refuses what was already transferred" 1 "is owned by" -- run "YES\nUPGRADECAP\n" --include-upgrade-cap

# multisig-address.sh validates its inputs before it asks the CLI for the address.
# msa: multisig-address.sh with the same inputs (it must refuse bad ones before it asks the CLI).
msa() { env PATH="$D/bin:$PATH" MULTISIG_PKS="${PKS-$PK1 $PK2}" MULTISIG_WEIGHTS="${WEIGHTS-1 1}" MULTISIG_THRESHOLD="${THRESHOLD-2}" bash "$D/scripts/multisig-address.sh"; }
WEIGHTS="1" expect "multisig-address.sh: keys and weights differ in number" 1 "2 keys but 1 weights" -- msa
THRESHOLD=5 expect "multisig-address.sh: a threshold above the total weight" 1 "must be between 1 and the total weight" -- msa
PKS="" expect "multisig-address.sh: no keys" 1 "MULTISIG_PKS" -- msa

# Summary and exit code.
if [ "$FAILS" -ne 0 ]; then printf '\n%s test(s) failed.\n' "$FAILS"; exit 1; fi
printf '\nall transfer-authority.sh tests passed.\n'
