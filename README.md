# 📺 IPTV Player - SwiftUI & AVKit

A modern, high-performance IPTV player built for iOS using **SwiftUI**, **AVKit**, and **Combine**.

<p align="center">
  <img src="https://github.com/mongoosemonke504/NebuloIPTV/blob/main/images/Settings.PNG" alt="Settings" width="200">
  <img src="https://github.com/mongoosemonke504/NebuloIPTV/blob/main/images/Sports%20Center.PNG" alt="Sports Hub" width="200">
  <img src="https://github.com/mongoosemonke504/NebuloIPTV/blob/main/images/Homescreen.PNG" alt="Home Page" width="200">
  <img src="[https://github.com/mongoosemonke504/NebuloIPTV/blob/main/images/Homescreen.PNG](https://github.com/mongoosemonke504/NebuloIPTV/blob/main/images/Multi-view.PNG)" alt="Multi-view" width="200">
</p>

## ✨ Features

* **Universal Login Support:**
    * **Xtream Codes API:** Standard login for most providers.
    * **M3U / M3U8 Playlists:** Powerful parser for local or remote playlist files.
    * **Stalker Portal:** Support for MAG-style portal links.
* **🏀 Intelligent Sports Center:**
    * **Real-Time Scores:** Integration with ESPN API for live scores.
    * **Smart Search:** Fuzzy matching logic automatically finds the best stream for a specific game (prioritizing 60fps/FHD streams).
    * **Multi-League Support:** NBA, NFL, MLB, NHL, Premier League, UCL, Europa League, Ligue 1, and more.
* **🎨 Nebula UI Engine:**
    * Custom, interactive animated background using SwiftUI `Canvas`.
    * Glassmorphic design with adaptable layouts (Sidebar for iPad/Landscape, Standard for iPhone).
    * Fully customizable colors and animation speeds.
* **⚡️ Advanced Player:**
    * **Picture-in-Picture (PiP):** Multitask while watching.
    * **AirPlay 2:** Cast directly to Apple TV or compatible smart TVs.
    * **Quality Detection:** Auto-tags streams as SD, HD, or 4K based on resolution.

## 🛠️ Tech Stack

* **Language:** Swift 5.10+
* **Frameworks:** SwiftUI, Combine, AVKit, AVFoundation
* **Architecture:** MVVM (Model-View-ViewModel)
* **Concurrency:** Swift Async/Await (`Task`, `Actor`)
* **Persistence:** `UserDefaults` (Settings, Favorites, Recents)

## 🚀 Getting Started

### Prerequisites
* Xcode 15.0 or later
* iOS 16.0 or later

### Installation
1. Download latest version from releases page
2. Sideload

## 🧩 Usage

1.  **Login:** Choose your method (Xtream, M3U, or Stalker) and enter your credentials/URL.
2.  **Browse:** Use the sidebar (iPad) or standard view (iPhone) to browse categories.
3.  **Sports:** Navigate to the "Sports Center" tab to see live games. Tapping a game automatically searches your playlist for that specific match using the Smart Search engine.
4.  **Settings:** Customize the "Nebula" background colors, toggle category visibility, or manage account settings.

## 🤝 Contributing

Contributions are welcome! Please follow these steps:
1.  Fork the project.
2.  Create your feature branch (`git checkout -b feature/AmazingFeature`).
3.  Commit your changes (`git commit -m 'Add some AmazingFeature'`).
4.  Push to the branch (`git push origin feature/AmazingFeature`).
5.  Open a Pull Request.

## ⚠️ Disclaimer

This application is a **video player**. It does **not** provide any content. Users must provide their own playlists or subscription details from a legal provider. The developers of this app do not condone piracy.

## 📄 License

Distributed under the MIT License. See `LICENSE` for more information.

---

### 💬 Community & Support

Join our Discord for updates, bug reports, and beta testing!
[**Join the Discord Server**]([https://discord.gg/PHc8AGV6](https://discord.gg/qf7rcFfE))
