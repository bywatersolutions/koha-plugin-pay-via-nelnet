# Pay via NelNet

This plugin allows Koha to accept payments from the OPAC using NelNet as a payment processor

# Downloading

From the [release page](https://github.com/bywatersolutions/koha-plugin-pay-via-nelnet/releases) you can download the relevant *.kpz file

# Installing

## Special Requirements
This plugin requires the Perl module URI::Encode to be installed before the plugin will load.


# Encrypting the key

The Nelnet shared key is encrypted at rest using Koha's own encryption, which needs an
`encryption_key` in `koha-conf.xml`. Koha does not generate one for you — a fresh instance ships
the placeholder `__ENCRYPTION_KEY__`, and Koha reports this on the About page.

```xml
<encryption_key>a random string of at least 32 bytes</encryption_key>
```

`pwgen 32 1` produces a suitable value. Restart Koha after adding it.

If no key is configured the plugin still works, but the shared key stays in cleartext and the
configuration page shows a warning. Once a key is set, the stored value is encrypted automatically
the next time the plugin is upgraded or its configuration page is opened.

Changing `encryption_key` after the shared key has been encrypted makes it unrecoverable. Payments
will fail with a clear error until the key is re-entered on the configuration page.

The shared key is never sent to Nelnet or shown to patrons — it is only an input to the SHA-256
hash that signs each payment request.
