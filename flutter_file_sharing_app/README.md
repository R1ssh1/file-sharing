# Flutter File Sharing App

## Overview
The Flutter File Sharing App allows users to share access to folders on their devices with peers. Users can manage download requests and control permissions for file previews, making it a versatile tool for file sharing.

## Features
- Share access to one or more folders on the device.
- Manage download requests from peers.
- Choose between automatic or manual request approvals.
- Control permissions for file previews.
- Chunked AES-GCM encrypted streaming with per-chunk framing.
- Optional gzip compression (server-side pre-encryption) negotiated via Accept-Encoding: gzip.
- In-band signed footer metadata (ver/type/state/hash/length/chunks/sig) providing final integrity & state (completed/failed/canceled).
- Folder-level ACLs (allow / deny peer lists) for fine-grained access control.
- Basic auth brute-force rate limiting & concurrent transfer caps.

## Project Structure
```
flutter_file_sharing_app
├── analysis_options.yaml
├── pubspec.yaml
├── README.md
├── .gitignore
├── lib
│   ├── main.dart
│   ├── app.dart
│   ├── core
│   │   ├── routing
│   │   │   └── app_router.dart
│   │   ├── theme
│   │   │   └── app_theme.dart
│   │   ├── utils
│   │   │   └── validators.dart
│   │   └── constants
│   │       └── app_constants.dart
│   ├── common
│   │   ├── widgets
│   │   │   └── loading_indicator.dart
│   │   └── extensions
│   │       └── context_extensions.dart
│   ├── features
│   │   └── file_sharing
│   │       ├── domain
│   │       │   ├── entities
│   │       │   │   ├── shared_folder.dart
│   │       │   │   ├── peer.dart
│   │       │   │   └── file_request.dart
│   │       │   ├── repositories
│   │       │   │   └── file_sharing_repository.dart
│   │       │   └── value_objects
│   │       │       └── permissions.dart
│   │       ├── data
│   │       │   ├── datasources
│   │       │   │   ├── local_storage_datasource.dart
│   │       │   │   └── peer_connection_datasource.dart
│   │       │   ├── models
│   │       │   │   ├── shared_folder_model.dart
│   │       │   │   ├── peer_model.dart
│   │       │   │   └── file_request_model.dart
│   │       │   └── repositories
│   │       │       └── file_sharing_repository_impl.dart
│   │       ├── application
│   │       │   ├── state
│   │       │   │   ├── folder_state.dart
│   │       │   │   ├── peer_state.dart
│   │       │   │   └── request_state.dart
│   │       │   └── cubits
│   │       │       ├── folder_cubit.dart
│   │       │       ├── peer_cubit.dart
│   │       │       └── request_cubit.dart
│   │       └── presentation
│   │           ├── pages
│   │           │   ├── home_page.dart
│   │           │   ├── folder_detail_page.dart
│   │           │   ├── peer_management_page.dart
│   │           │   └── requests_page.dart
│   │           ├── widgets
│   │           │   ├── folder_tile.dart
│   │           │   ├── peer_tile.dart
│   │           │   └── request_tile.dart
│   │           └── dialogs
│   │               ├── add_folder_dialog.dart
│   │               └── permissions_dialog.dart
│   ├── services
│   │   ├── networking
│   │   │   ├── peer_discovery_service.dart
│   │   │   └── transfer_protocol_service.dart
│   │   ├── permissions
│   │   │   └── permission_service.dart
│   │   └── file
│   │       └── file_access_service.dart
│   └── di
│       └── service_locator.dart
├── assets
│   └── translations
│       └── en.json
├── test
│   ├── widget
│   │   └── home_page_test.dart
│   ├── domain
│   │   └── shared_folder_entity_test.dart
│   └── data
│       └── file_sharing_repository_impl_test.dart
├── android
├── ios
├── web
├── macos
├── linux
└── windows
```

## Getting Started
1. Clone the repository.
2. Navigate to the project directory.
3. Run `flutter pub get` to install dependencies.
4. Use `flutter run` to start the application.

## Contributing
Contributions are welcome! Please open an issue or submit a pull request for any enhancements or bug fixes.

## License
## Protocol Overview

### Transfer Stream Framing
Each encrypted chunk frame: `[4-byte big-endian cipherLen][cipher bytes][16-byte GCM tag]`.

After the last encrypted frame a clear (plaintext) metadata footer is appended:
`[4-byte big-endian metaLen][JSON meta]` where JSON fields:
```
{"ver":1,"type":"final|failed|canceled","state":"completed|failed|canceled","hash":"<sha256-hex>","length":<plain_bytes>,"chunks":<count>,"sig":"<hmac-sha256>"}
```
`sig` = HMAC-SHA256 over the JSON without `sig` using key = SHA256(fileKey || 'footer').

Clients verify footer HMAC for authenticity and map `state` to local completion, cancel, or failure.

### Compression
If client sends `Accept-Encoding: gzip` and file size >= 8KB, the server gzip-compresses plaintext prior to encryption; header `Content-Encoding: gzip` is set. Hash is computed over original plaintext (pre-compression) ensuring consistent integrity verification.

### ACL Enforcement
Shared folders may define `allowedPeerIds` (whitelist) or `deniedPeerIds` (blacklist). Whitelist takes precedence: if present, only those peers succeed. Otherwise deny list blocks listed peers.

### Rate Limiting & Auth
Auth failures tracked per peer identity with lockout after repeated failures (HTTP 429 `auth_rate_limited`). Concurrent transfer caps enforced globally and per peer with 429 `rate_limited` JSON responses.

## Future Work
- Adaptive chunk sizing / congestion control
- Encrypted footer (currently signed only)
- Extended metrics & compression negotiation variants
- Full DI refactor and platform manifests
This project is licensed under the MIT License. See the LICENSE file for details.