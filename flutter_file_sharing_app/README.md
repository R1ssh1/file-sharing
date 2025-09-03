# 📁 Flutter File Sharing App

<div align="center">
  <img src="https://img.shields.io/badge/Flutter-02569B?style=for-the-badge&logo=flutter&logoColor=white" alt="Flutter"/>
  <img src="https://img.shields.io/badge/Dart-0175C2?style=for-the-badge&logo=dart&logoColor=white" alt="Dart"/>
  <img src="https://img.shields.io/badge/License-MIT-green.svg?style=for-the-badge" alt="License"/>
  <img src="https://img.shields.io/badge/Version-1.0.0-blue.svg?style=for-the-badge" alt="Version"/>
</div>

## 📖 Overview

A secure, cross-platform Flutter application that enables peer-to-peer file sharing with advanced encryption and access control features. Built with clean architecture principles and comprehensive security measures, this app allows users to share folders securely across devices while maintaining full control over permissions and access.

## ✨ Key Features

### 🔐 Security & Encryption
- **AES-GCM Encryption**: Chunked streaming with per-chunk framing for secure data transmission
- **Cryptographic Signatures**: In-band signed footer metadata for integrity verification
- **Trust Management**: Peer trust system with persistent trust relationships
- **Rate Limiting**: Built-in protection against brute-force authentication attempts

### 📂 File Management
- **Multi-Folder Sharing**: Share access to multiple folders simultaneously
- **Request Management**: Handle download requests with automatic or manual approval
- **Preview Controls**: Fine-grained permissions for file previews
- **Resume Downloads**: Support for resuming interrupted transfers

### 🌐 Network & Discovery
- **Multicast DNS**: Automatic peer discovery on local networks
- **HTTP Server**: Built-in local server for file serving
- **Compression Support**: Optional gzip compression negotiated via Accept-Encoding
- **Concurrent Transfer Management**: Control simultaneous transfer limits

### 🛡️ Access Control
- **Folder-level ACLs**: Allow/deny lists for granular access control
- **Peer Authentication**: Secure peer-to-peer authentication system
- **Request Validation**: Comprehensive validation of all incoming requests

## 🏗️ Architecture

This project follows **Clean Architecture** principles with clear separation of concerns:

```
lib/
├── main.dart                          # Application entry point
└── features/
    └── file_sharing/
        ├── data/                      # Data layer
        │   ├── datasources/           # External data sources
        │   └── repositories/          # Repository implementations
        ├── domain/                    # Business logic layer
        │   ├── entities/              # Core business objects
        │   └── repositories/          # Repository contracts
        ├── infrastructure/            # External services & utilities
        └── presentation/              # UI layer
            └── pages/                 # Application screens
├── pubspec.yaml
├── README.md
├── .gitignore
├── lib
│   ├── main.dart
│   ├── app.dart
│   ├── core
│   │   ├── routing
```

## 🏗️ Core Components

### Infrastructure Layer
- **LocalHttpServer**: Handles HTTP requests and file serving
- **EncryptionService**: Manages AES-GCM encryption and decryption
- **PeerDiscoveryService**: Implements mDNS for automatic peer discovery
- **TrustManager**: Manages peer trust relationships and certificates
- **PermissionService**: Handles device permissions for file access
- **ClientDownloadService**: Manages file downloads and resume functionality

### Data Persistence
- **Hive**: Local database for storing shared folders and file requests
- **SharedFolder**: Entity representing folders available for sharing
- **FileRequest**: Entity tracking download requests and their status

## 🚀 Getting Started

### Prerequisites
- Flutter SDK (>=2.17.0 <4.0.0)
- Dart SDK
- Android Studio / VS Code with Flutter extension
- Android/iOS device or emulator

### Installation

1. **Clone the repository**
   ```bash
   git clone https://github.com/R1ssh1/file-sharing.git
   cd flutter_file_sharing_app
   ```

2. **Install dependencies**
   ```bash
   flutter pub get
   ```

3. **Generate required files**
   ```bash
   flutter packages pub run build_runner build
   ```

4. **Run the application**
   ```bash
   flutter run
   ```

### Platform-Specific Setup

#### Android
- Minimum SDK: API level 21 (Android 5.0)
- Required permissions are automatically handled by the app

#### iOS
- iOS 11.0+
- Permissions are requested at runtime

#### Desktop (Windows/macOS/Linux)
- Full desktop support with native file system access

## 📱 Usage

### Setting Up File Sharing

1. **Add Folders**: Use the "+" button to select folders you want to share
2. **Configure Permissions**: Set access control lists for each folder
3. **Start Server**: The app automatically starts a local HTTP server
4. **Peer Discovery**: Other devices on the network will automatically discover your shared folders

### Managing Requests

- **Automatic Approval**: Enable for trusted networks
- **Manual Review**: Review each download request individually  
- **Request History**: View all past requests and their status

### Security Features

- **Trust Management**: Build a network of trusted peers
- **Encryption**: All transfers are encrypted end-to-end
- **Rate Limiting**: Protection against malicious requests

## 🧪 Testing

The project includes comprehensive tests covering:

```bash
# Run all tests
flutter test

# Run specific test suites
flutter test test/domain/
flutter test test/infrastructure/
flutter test test/widget/
```

### Test Coverage Areas
- **Unit Tests**: Domain entities and business logic
- **Integration Tests**: Repository implementations and services
- **Widget Tests**: UI components and user interactions
- **Infrastructure Tests**: Encryption, networking, and security features

## 🔧 Configuration

### Server Configuration
```dart
// Default server settings
const int DEFAULT_PORT = 8080;
const int MAX_CONCURRENT_TRANSFERS = 5;
const int CHUNK_SIZE = 64 * 1024; // 64KB chunks
```

### Security Settings
```dart
// Encryption configuration
const int AES_KEY_LENGTH = 256;
const int GCM_TAG_LENGTH = 16;
const int NONCE_LENGTH = 12;
```

## 📚 Dependencies

### Core Dependencies
- **flutter**: UI framework
- **provider**: State management
- **flutter_bloc**: Business logic components
- **hive**: Local database
- **shelf**: HTTP server framework

### Security & Networking
- **pointycastle**: Cryptographic operations
- **multicast_dns**: Peer discovery
- **http**: Network requests
- **uuid**: Unique identifier generation

### Platform Integration
- **permission_handler**: Device permissions
- **path_provider**: File system access
- **file_picker**: File selection
- **device_info_plus**: Device information

## 🤝 Contributing

We welcome contributions! Please see our [Contributing Guidelines](CONTRIBUTING.md) for details.

### Development Workflow

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Make your changes
4. Add tests for new functionality
5. Ensure all tests pass (`flutter test`)
6. Commit your changes (`git commit -m 'Add amazing feature'`)
7. Push to the branch (`git push origin feature/amazing-feature`)
8. Open a Pull Request

### Code Style
- Follow [Dart Style Guide](https://dart.dev/guides/language/effective-dart/style)
- Use meaningful variable and function names
- Add documentation for public APIs
- Maintain test coverage above 80%

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🙏 Acknowledgments

- Flutter team for the excellent framework
- The open-source community for various packages used
- Contributors who helped improve this project

## 📞 Support

If you encounter any issues or have questions:

- Open an [Issue](https://github.com/R1ssh1/file-sharing/issues)
- Check the [FAQ](FAQ.md)
- Review existing [Discussions](https://github.com/R1ssh1/file-sharing/discussions)

## 🗺️ Roadmap

- [ ] Cloud storage integration
- [ ] Enhanced UI/UX improvements
- [ ] Advanced file filtering options
- [ ] Cross-platform desktop optimizations
- [ ] Integration with popular cloud services
- [ ] Advanced analytics and logging

---

<div align="center">
  Made with ❤️ using Flutter
</div>
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