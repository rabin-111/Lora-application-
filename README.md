# Lora-application-

A Flutter application for long-range wireless communication using ESP32 in remote place where there is no internet and satellite access.

APPLICATION:  
This project presents the design and implementation of a Decentralized LoRa-based
Communication System for Remote Areas. In many rural and geographically isolated
regions, reliable communication infrastructure is limited or unavailable due to high de-
ployment costs and difficult terrain. To address this challenge, the proposed system
utilizes LoRa (Long Range) technology to enable low-power, long-distance wireless
communication without relying on centralized network infrastructure.
The system is designed to operate in a decentralized manner where each node can
communicate directly with other nodes, ensuring flexibility and improved network re-
silience. This approach eliminates the dependency on base stations or internet con-
nectivity, making it suitable for emergency communication, rural connectivity, and IoT
applications in remote environments.
The performance of the system is evaluated based on communication range, power effi-
ciency, and reliability. The results indicate that LoRa technology is highly effective for
establishing long-range communication with minimal power consumption. This makes
the proposed system a cost-effective and practical solution for improving connectivity
in remote and underserved areas..

# FEATURES: 
# Bluetooth Connectivity
Automatic device scanning and discovery
Easy pairing with ESP32-based LoRa devices
Real-time connection status monitoring
Supports Nordic UART Service (NUS) protocol
# Messaging
Send and receive messages through LoRa network
Real-time message delivery and display
Message history with timestamps
Clean, intuitive chat interface

# Technical Stack
Framework: Flutter 3.x
Language: Dart (SDK ^3.10.8)
BLE Communication: flutter_blue_plus (v1.32.12)
Permissions: permission_handler (v11.3.0)
Platform Support: Android

# Prerequisites
Flutter SDK 3.x or higher
Dart SDK 3.10.8 or higher
ESP32 device with LoRa module and BLE capabilities
ESP32 firmware configured with Nordic UART Service UUIDs:
Service UUID: 6e400001-b5a3-f393-e0a9-e50e24dcca9e
RX Characteristic: 6e400002-b5a3-f393-e0a9-e50e24dcca9e (Phone → ESP32)
TX Characteristic: 6e400003-b5a3-f393-e0a9-e50e24dcca9e (ESP32 → Phone)

# Usage
# Connecting to ESP32
Launch the app
Tap the "Connect" button in the top-right corner
Wait for device scanning to complete
Select your ESP32 device from the list
Once connected, the status will change to "Connected"
# Sending Messages
Navigate to the "Messages" tab
Type your message in the input field at the bottom
Press the send button
Messages are transmitted via LoRa network to other connected devices
## Tech Stack

- Flutter
- Dart
- ESP32
- BLE
- LoRa

## Project Structure

```bash
lib/        -> Main application source code
assets/     -> Images, fonts, and static assets
android/    -> Android platform files
ios/        -> iOS platform files
```

## Requirements

- Flutter SDK
- Dart SDK
- Android Studio or VS Code

## Installation

Clone the repository:

```bash
git clone https://github.com/rabin-111/Lora-application-

Move into the project directory:

```bash
cd project-name
```

Install dependencies:

```bash
flutter pub get
```

Run the project:

```bash
flutter run
```

## Build APK

```bash
flutter build apk
```
 # Author Rabin Poudel


