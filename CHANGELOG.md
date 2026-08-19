# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **A nightly cleanup of abandoned checkout tokens.** Tokens were only removed when a payment
  completed, so rows from checkouts that were started and abandoned accumulated forever. The
  plugin now implements Koha's `cronjob_nightly` hook (run daily by the packages out of the box)
  and removes tokens older than seven days.

### Fixed

- **The token table's foreign key constraint is now named uniquely.** All of ByWater's payment
  plugins named theirs `token_bn`, and constraint names are database-global — so installing a
  second payment plugin on the same instance failed with "Duplicate key on write or update".
  Existing installs are unaffected; fresh installs now use a per-plugin name.

## [1.3.0] - 2026-08-19

### Security

- **The shared key is no longer transmitted in the payment link.** It was emitted as a `key=`
  parameter in the link the patron clicks, visible to any patron in the OPAC page source, in
  browser history, and in Referer headers. Nelnet's Commerce Manager specification states the key
  must not be passed — it is only an input to the SHA-256 hash, which Nelnet validates using its own
  stored copy. The hash this plugin sends is byte-identical before and after this change, since the
  key was already the final element of the hash input.
- The shared key is now encrypted at rest with `Koha::Encryption` (AES-256-CBC) instead of being
  stored in cleartext in Koha's `plugin_data` table. Existing keys are migrated automatically on
  upgrade.
- The configuration form now submits via `POST` with a CSRF token, and no longer renders the stored
  key back into the page. The field is a password input and is left blank; leave it blank to keep
  the existing key.

### Removed

- The unused `URI::Encode` dependency. The module was loaded and never used — its only call was
  commented out — and it forced sites to install a Perl module the plugin does nothing with.

### Added

- `upgrade()`, which encrypts a key still held in cleartext. It is idempotent, and never throws.
- `t/db_dependent/PayViaNelnet.t`, covering the migration, its idempotency, the cleartext fallback,
  and the fail-closed paths.
- CI now runs `prove` recursively with the plugin directory on the include path.

### Notes

- The hash is unchanged, so this release should be transparent to Nelnet — but we recommend one
  test transaction against Nelnet's UAT environment (`uatquikpayasp.com`) before upgrading
  production sites, as belt and braces.
- Encryption needs an `encryption_key` in `koha-conf.xml`; Koha does not generate one. Without it
  the plugin behaves as before and the configuration page shows a warning.
- Encryption requires Koha 22.05 or newer. On older versions the plugin runs unchanged.
