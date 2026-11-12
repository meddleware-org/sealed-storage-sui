# Changelog

All notable changes to `@meddleware/sealed-storage-sui` are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.0.12] - 2026-11-12

transfer-authority.sh re-derives the multisig address from MULTISIG_PKS, MULTISIG_WEIGHTS and MULTISIG_THRESHOLD and refuses on a mismatch; the UpgradeCap needs its own UPGRADECAP confirmation; offline tests for the transfer script and multisig-address.sh.
