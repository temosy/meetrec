# Mac App Store release notes

## App identity

- App Store app name: MeetRec Recorder
- Installed app name: MeetRec
- Bundle ID: `jp.temosy.meetrec`
- SKU suggestion: `meetrec-macos`
- Price: Free
- Primary category: Productivity
- Secondary category: Utilities

## Signing and packaging

Install the Mac App Store distribution certificates in Keychain:

- `3rd Party Mac Developer Application`
- `3rd Party Mac Developer Installer`

Create a **Mac App Store Connect** distribution provisioning profile for
`jp.temosy.meetrec` at <https://developer.apple.com/account/resources/profiles/list>
and save the downloaded file as:

```
app-store/profiles/MeetRec.provisionprofile
```

The build script embeds it at `MeetRec.app/Contents/embedded.provisionprofile`
before code signing. Without it, App Store Connect reports warning ITMS-90889 and
the uploaded build is not eligible for TestFlight. App Review itself still accepts
such a build, but TestFlight distribution is blocked.

Then build the upload package:

```sh
scripts/build-app-store.sh
```

The script signs the app with `entitlements/app-store.entitlements` and produces `MeetRec-AppStore.pkg`.

## Entitlements

- `com.apple.application-identifier` — `3DU98362VP.jp.temosy.meetrec`
- `com.apple.developer.team-identifier` — `3DU98362VP`
- `com.apple.security.app-sandbox`
- `com.apple.security.device.microphone`
- `com.apple.security.files.user-selected.read-write`
- `com.apple.security.assets.movies.read-write`

MeetRec saves to `~/Movies/Meetings` by default and also lets users choose another folder.

## App Store Connect metadata

Localized text is in:

- `app-store/metadata/ja-JP/`
- `app-store/metadata/en-US/`

Review notes are in:

- `app-store/review-notes.txt`

Privacy policy:

- `PRIVACY.md`

## Screenshots

Prepared Mac screenshots:

- `app-store/screenshots/ja-JP/01-main-2880x1800.png`
- `app-store/screenshots/en-US/01-main-2880x1800.png`

## Upload

After creating the App Store Connect app record, validate or upload the package with Apple tools, for example:

```sh
xcrun altool --validate-app MeetRec-AppStore.pkg --api-key "$APPSTORE_API_KEY" --api-issuer "$APPSTORE_ISSUER_ID"
xcrun altool --upload-package MeetRec-AppStore.pkg --api-key "$APPSTORE_API_KEY" --api-issuer "$APPSTORE_ISSUER_ID"
```
