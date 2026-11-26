# Changelog

All notable changes to `@meddleware/sealed-storage-sui` are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Changed

- Documentation: every file is annotated line by line and has a header (every declaration of the modules and their tests has a doc comment); `CONTRIBUTING.md` and `AGENTS.md` added; README Development section; CLAUDE.md Commands, Gotchas and Related.
- The README says 41 tests (it said 37), and two test comments name `sealed-storage-client` (they named the old repository, `seal-client`).
- No behaviour change: the compiled bytecode of every module, tests included, is identical.

## [0.0.12] - 2026-11-12

transfer-authority.sh re-derives the multisig address from MULTISIG_PKS, MULTISIG_WEIGHTS and MULTISIG_THRESHOLD and refuses on a mismatch; the UpgradeCap needs its own UPGRADECAP confirmation; offline tests for the transfer script and multisig-address.sh.
