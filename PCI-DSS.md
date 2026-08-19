# PCI DSS scoping statement — Pay Via Nelnet

This document describes what data the **Pay Via Nelnet** Koha plugin sends to Nelnet, what Nelnet
sends back, and what Koha retains.

It is a factual description of the plugin's behaviour at the commit named in section 8 (the v1.3.0
release). It is not a certification, and it does not determine any library's PCI DSS obligations —
a library that accepts card payments is a merchant and has obligations regardless of what Koha
does. What this document establishes is whether Koha itself sits inside the cardholder data
environment.

---

## 1. Summary

| Assertion | Determination |
|---|---|
| Does this plugin **accept** cardholder data (PAN, CVV/CVC/CID, expiry date, track or chip data, PIN)? | **No** |
| Does this plugin **transmit** cardholder data to any system? | **No** |
| Does this plugin **store** cardholder data? | **No** |
| Does this plugin store any **card-derived** data (card brand, truncated PAN, authorisation code)? | **No** |
| Does the patron ever enter card details into a page served by Koha? | **No** |
| Does any Koha-served page frame, embed, script, or otherwise affect the processor's card-entry page? | **No** |

**Determination: Koha is outside the cardholder data environment.**

A patron who chooses to pay library fees online leaves the Koha catalogue entirely by clicking a
link to Nelnet's QuikPAY hosted payment page. Card details are typed into that page, travel to
Nelnet, and never reach Koha or ByWater Solutions' servers. When the payment completes, Nelnet
returns the patron to Koha with the result, and Koha marks the selected fees as paid.

### One term that looks like card data and is not

**Koha's `cardnumber` is a library card barcode, not a payment card number.** This plugin does
not transmit or store it in any case.

---

## 2. How a payment works

1. The patron selects fees in the OPAC. [`opac_online_payment_begin`](https://github.com/bywatersolutions/koha-plugin-pay-via-nelnet/blob/2df78b7f516818987421995af919a8a037674acb/Koha/Plugin/Com/ByWaterSolutions/PayViaNelnet.pm#L64) records a
   [one-time token](https://github.com/bywatersolutions/koha-plugin-pay-via-nelnet/blob/2df78b7f516818987421995af919a8a037674acb/Koha/Plugin/Com/ByWaterSolutions/PayViaNelnet.pm#L88) and builds the QuikPAY request as a signed URL.
2. **Patron's browser** [follows that link](https://github.com/bywatersolutions/koha-plugin-pay-via-nelnet/blob/2df78b7f516818987421995af919a8a037674acb/Koha/Plugin/Com/ByWaterSolutions/PayViaNelnet/opac_online_payment_begin.tt#L82) to Nelnet's hosted page and the patron enters
   card details there. Koha is not involved and receives nothing from that step.
3. **Nelnet** redirects the patron back with the [requested result parameters](https://github.com/bywatersolutions/koha-plugin-pay-via-nelnet/blob/2df78b7f516818987421995af919a8a037674acb/Koha/Plugin/Com/ByWaterSolutions/PayViaNelnet.pm#L97);
   [`opac_online_payment_end`](https://github.com/bywatersolutions/koha-plugin-pay-via-nelnet/blob/2df78b7f516818987421995af919a8a037674acb/Koha/Plugin/Com/ByWaterSolutions/PayViaNelnet.pm#L146) validates the token and
   [credits the payment](https://github.com/bywatersolutions/koha-plugin-pay-via-nelnet/blob/2df78b7f516818987421995af919a8a037674acb/Koha/Plugin/Com/ByWaterSolutions/PayViaNelnet.pm#L205).

**The request is signed, and the signing secret never leaves the server.** The parameters are
joined and hashed SHA-256 [with the shared key appended as the final element](https://github.com/bywatersolutions/koha-plugin-pay-via-nelnet/blob/2df78b7f516818987421995af919a8a037674acb/Koha/Plugin/Com/ByWaterSolutions/PayViaNelnet.pm#L120) —
Nelnet's Commerce Manager specification's construction — and only the parameters plus the `hash`
travel. As of v1.3.0 the key itself is **not** among them; see §7.

## 3. Data sent to the payment processor

[Parameters of the payment link](https://github.com/bywatersolutions/koha-plugin-pay-via-nelnet/blob/2df78b7f516818987421995af919a8a037674acb/Koha/Plugin/Com/ByWaterSolutions/PayViaNelnet.pm#L100): order type, the first accountline id as order number,
the patron's first and last name, the literal description "Payment of library fees", the amount in
cents, borrowernumber ([`userChoice1`](https://github.com/bywatersolutions/koha-plugin-pay-via-nelnet/blob/2df78b7f516818987421995af919a8a037674acb/Koha/Plugin/Com/ByWaterSolutions/PayViaNelnet.pm#L105)), the accountline ids, the one-time token, the
return URL and its requested echo parameters, retries, and a [timestamp](https://github.com/bywatersolutions/koha-plugin-pay-via-nelnet/blob/2df78b7f516818987421995af919a8a037674acb/Koha/Plugin/Com/ByWaterSolutions/PayViaNelnet.pm#L111), plus the
SHA-256 `hash`.

**Cardholder data in this table: none.** No PAN, CVV, expiry, track or PIN field is constructed
anywhere in this plugin. No address, email, phone, or fee descriptions are sent — the patron PII
surface is name and borrowernumber.

## 4. Data received from the payment processor

**Transport:** the patron's return to `opac-account-pay-return.pl`, carrying the
[parameters the plugin asked Nelnet to echo](https://github.com/bywatersolutions/koha-plugin-pay-via-nelnet/blob/2df78b7f516818987421995af919a8a037674acb/Koha/Plugin/Com/ByWaterSolutions/PayViaNelnet.pm#L97).
**Authentication of this channel:** the patron's authenticated OPAC session plus the one-time
token.

Read: [borrowernumber](https://github.com/bywatersolutions/koha-plugin-pay-via-nelnet/blob/2df78b7f516818987421995af919a8a037674acb/Koha/Plugin/Com/ByWaterSolutions/PayViaNelnet.pm#L162), accountline ids, token,
[`transactionStatus`](https://github.com/bywatersolutions/koha-plugin-pay-via-nelnet/blob/2df78b7f516818987421995af919a8a037674acb/Koha/Plugin/Com/ByWaterSolutions/PayViaNelnet.pm#L166), [`transactionId`](https://github.com/bywatersolutions/koha-plugin-pay-via-nelnet/blob/2df78b7f516818987421995af919a8a037674acb/Koha/Plugin/Com/ByWaterSolutions/PayViaNelnet.pm#L167), and
[`orderAmount`](https://github.com/bywatersolutions/koha-plugin-pay-via-nelnet/blob/2df78b7f516818987421995af919a8a037674acb/Koha/Plugin/Com/ByWaterSolutions/PayViaNelnet.pm#L169). **No card data is requested or read** — no masked PAN, brand, expiry,
or authorisation code is in the echo list.

## 5. What Koha stores, and for how long

| Store | Contents | Retention |
|---|---|---|
| [`nelnet_plugin_tokens`](https://github.com/bywatersolutions/koha-plugin-pay-via-nelnet/blob/2df78b7f516818987421995af919a8a037674acb/Koha/Plugin/Com/ByWaterSolutions/PayViaNelnet.pm#L445) | one-time token, created_on, borrowernumber | Deleted on successful payment. As of v1.4.0, a nightly job removes tokens older than seven days; at the reviewed commit, abandoned rows accumulated with no purge. Not dropped on [uninstall](https://github.com/bywatersolutions/koha-plugin-pay-via-nelnet/blob/2df78b7f516818987421995af919a8a037674acb/Koha/Plugin/Com/ByWaterSolutions/PayViaNelnet.pm#L464). |
| `accountlines` | amount; note [`Paid via NelNet: <sha256 of transactionId>`](https://github.com/bywatersolutions/koha-plugin-pay-via-nelnet/blob/2df78b7f516818987421995af919a8a037674acb/Koha/Plugin/Com/ByWaterSolutions/PayViaNelnet.pm#L184) — the transaction id is stored **hashed**, and doubles as the duplicate-payment check | Per the library's Koha retention settings |
| `plugin_data` | configuration; the shared key **encrypted** (AES-256-CBC via `Koha::Encryption`, [`koha-enc-v1:` prefix](https://github.com/bywatersolutions/koha-plugin-pay-via-nelnet/blob/2df78b7f516818987421995af919a8a037674acb/Koha/Plugin/Com/ByWaterSolutions/PayViaNelnet.pm#L38), since v1.3.0) | Until changed |

**Logs: nothing.** The one debug `warn` in the return path is commented out; no payment data
reaches the log.

**Credentials:** the shared key is decrypted only [at the point of hashing](https://github.com/bywatersolutions/koha-plugin-pay-via-nelnet/blob/2df78b7f516818987421995af919a8a037674acb/Koha/Plugin/Com/ByWaterSolutions/PayViaNelnet.pm#L341 ), migrated
from cleartext [on upgrade](https://github.com/bywatersolutions/koha-plugin-pay-via-nelnet/blob/2df78b7f516818987421995af919a8a037674acb/Koha/Plugin/Com/ByWaterSolutions/PayViaNelnet.pm#L433) and on visiting the configuration page, and the
configuration form posts with a CSRF token without ever rendering the stored key.

## 6. Patron personal data (outside PCI scope)

Patron first and last name and borrowernumber go to Nelnet in the payment link's query string —
which, being a GET navigation, also lands in browser history. No address, email, phone, or fee
descriptions are transmitted. Once transmitted, Nelnet's handling is governed by their privacy
policy and the library's agreement with them.

## 7. Known limitations

| Item | Bearing on this document | Status |
|---|---|---|
| The shared signing key was emitted as a `key=` parameter in the payment link — readable by any patron in the OPAC page source, browser history, and Referer headers. Nelnet's specification marks the key "Passed to QuikPAY: No"; the hash is byte-identical without it. | Credential exposure, not cardholder data. | **Remediated in v1.3.0** — the key now exists only in the hash input. One UAT transaction before production upgrades is recommended in the CHANGELOG, belt and braces |
| The shared key was stored in cleartext in `plugin_data`. | Credential exposure. | **Remediated in v1.3.0** — encrypted at rest, migrated on upgrade |
| The return leg trusts the echoed parameters; the hash signs the outbound request, not the return. The one-time token and the hashed-note duplicate check are the controls. | Payment-record integrity, not card data. | Open |
| Parameter values are not URL-encoded when the link is built (an encode call is commented out), so a patron name containing `&` or `=` corrupts the query string and the hash. | Payment availability, not card data. | Open |
| If Nelnet's return were delivered as a POST, Koha's CSRF middleware would reject it before this plugin runs ([Koha bug 41197](https://bugs.koha-community.org/bugzilla3/show_bug.cgi?id=41197), Passed QA). The `redirectUrl` mechanism implies a GET redirect, but the method is not determinable from this code. | Whether the return leg works; no card data involved. | Open question |

## 8. What was reviewed

Reviewed at commit [`2df78b7f516818987421995af919a8a037674acb`](https://github.com/bywatersolutions/koha-plugin-pay-via-nelnet/commit/2df78b7f516818987421995af919a8a037674acb) (the v1.3.0 release) on 2026-08-19:
[`PayViaNelnet.pm`](https://github.com/bywatersolutions/koha-plugin-pay-via-nelnet/blob/2df78b7f516818987421995af919a8a037674acb/Koha/Plugin/Com/ByWaterSolutions/PayViaNelnet.pm), the OPAC templates, and the configuration template. The Nelnet
Commerce Manager Pass-through Authentication Specification (v2.4) was used for the signing
construction and the key-transmission rule.

| Date | Version | Commit | Reviewer | Change |
|---|---|---|---|---|
| 2026-08-19 | v1.3.0 | `2df78b7` | Kyle M Hall | Initial review |
