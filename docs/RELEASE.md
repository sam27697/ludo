# Release: from a push to something you can upload to Play

This is for whoever is holding the upload keystore and doing the Play
Console work. It assumes no prior context on this repository's release
setup.

## The two kinds of release build

Every push to this repository builds the Android app in release mode, in
the `client` job of `.github/workflows/verify.yml`. Whether that build is
something you can actually give to Play depends entirely on whether five
secrets are configured on the repository (see below). If they are not, the
job still builds and tests the app in release mode -- so a broken release
build is still caught on every push, including pushes from a fork with no
access to secrets -- but it signs with the Flutter template's debug key and
uploads nothing. Play rejects a debug-signed bundle, and a debug-signed
bundle is never put where anyone could find it and try anyway.

When the five secrets are configured, the job:

1. writes the keystore and `android/key.properties` from the secrets, inside
   that run only,
2. builds the release bundle, which now signs with the real upload key,
3. checks the built bundle's signer certificate against
   `LUDO_UPLOAD_CERT_SHA256`, and fails the job if it does not match,
4. uploads the bundle as a workflow artifact named
   `ludo-release-appbundle`, kept for 14 days.

Nothing written in step 1 survives past the run. GitHub Actions runners are
discarded after the job finishes.

## Generating the upload keystore

The keystore is a PKCS12 file, generated with `openssl`, not a JKS file
generated with `keytool`. Run this on a machine you trust, not in this
repository, and never commit anything it produces:

    openssl req -x509 -newkey rsa:4096 -sha256 -days 10000 \
      -keyout /tmp/upload-key.pem \
      -out /tmp/upload-cert.pem \
      -subj "/CN=Ludo Upload Key" \
      -nodes

    openssl pkcs12 -export \
      -inkey /tmp/upload-key.pem \
      -in /tmp/upload-cert.pem \
      -out upload-keystore.p12 \
      -name upload \
      -passout pass:CHOOSE_A_STORE_PASSWORD

The `-name upload` value is the key alias; it does not have to be `upload`,
but whatever it is, it is `LUDO_UPLOAD_KEY_ALIAS` below. This project uses a
single password for both the store and the key, so `storePassword` and
`keyPassword` can be the same value, but they do not have to be.

Delete `/tmp/upload-key.pem` and `/tmp/upload-cert.pem` once
`upload-keystore.p12` exists, or move them somewhere with the same handling
as the keystore itself. Keep `upload-keystore.p12` somewhere durable and
offline -- if it is lost and this app is not enrolled in Play App Signing,
the app can never be updated again under this `applicationId`. If it is
enrolled in Play App Signing (this project's stated choice, see
`docs/STACK.md`), Google can reset the upload key on request with proof of
ownership, but that is a slow process you do not want to need.

## Getting the certificate fingerprint

    keytool -printcert -jarfile upload-keystore.p12

does not work directly on the raw `.p12` -- `-jarfile` wants a signed jar or
bundle, not a keystore. To print the certificate fingerprint of the key
inside the keystore itself, use:

    keytool -list -v -keystore upload-keystore.p12 -storetype PKCS12 \
      -storepass CHOOSE_A_STORE_PASSWORD -alias upload

and read the `SHA256:` line under "Certificate fingerprints". It prints as
upper-case hex with colons, for example:

    AB:CD:12:34:...

That exact string, unmodified, is `LUDO_UPLOAD_CERT_SHA256`.

## The secrets

Set these on the repository (Settings, Secrets and variables, Actions).
Every name is exact; the workflow will not find them under any other name.

| Secret | Value |
|---|---|
| `LUDO_UPLOAD_KEYSTORE_B64` | `base64 -w0 upload-keystore.p12`, the whole output |
| `LUDO_UPLOAD_STORE_PASSWORD` | the store password chosen above |
| `LUDO_UPLOAD_KEY_PASSWORD` | the key password chosen above |
| `LUDO_UPLOAD_KEY_ALIAS` | the alias chosen above, `upload` if you followed this document exactly |
| `LUDO_UPLOAD_CERT_SHA256` | the `SHA256:` fingerprint printed above, upper-case hex with colons |

`LUDO_UPLOAD_KEYSTORE_B64` is the only one of the five that is not a
password. It is the keystore file itself, base64-encoded so it survives
being stored as a single-line secret. On the machine holding
`upload-keystore.p12`:

    base64 -w0 upload-keystore.p12

and paste the output as the secret value. `-w0` matters: without it some
`base64` implementations wrap the output at 76 characters, and a
newline-wrapped value pasted into the GitHub secret box is still valid
base64 either way, but keeping it on one line avoids any doubt.

## Downloading the artifact from an Actions run

Once the secrets are set and a build has run:

1. open the repository's Actions tab,
2. open the `verify` workflow run for the commit you want,
3. open the `client` job,
4. under the run summary, the artifact `ludo-release-appbundle` is listed;
   download it as a zip and unzip it to get the `.aab`.

If the artifact is not there, either the five secrets are not all set, or
the certificate fingerprint check failed and the job stopped before
uploading. Both cases are visible in the job log: the "write release
signing material" step says outright whether the secrets are configured,
and the "verify the release bundle is signed with the expected upload
certificate" step says outright why it failed if it did.

## The one thing that will bite later: assetlinks.json

When this app eventually serves `assetlinks.json` for Android App Links,
the fingerprint that file needs is the **app signing key** fingerprint from
the Play Console's App integrity page (App signing, App signing key
certificate), not `LUDO_UPLOAD_CERT_SHA256` and not any fingerprint printed
from `upload-keystore.p12`.

Under Play App Signing, the key you hold and use in this repository only
signs the upload; Google re-signs the app for distribution with a separate
key it holds, and that second key is the one every installed copy of the
app is actually signed with on a user's device. `assetlinks.json` has to
match what is on the device, so it has to match the app signing key, not
the upload key.

Putting the upload key's fingerprint in `assetlinks.json` by mistake does
not produce an error anywhere. It fails silently: Android's Digital Asset
Links verification just does not match, so links that were supposed to
open directly in the app open in a browser instead, and nothing in any log
says why. If deep links stop opening the app, this mismatch is the first
thing to check.
