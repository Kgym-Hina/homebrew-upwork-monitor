# Upwork Monitor

Upwork Monitor is a native SwiftUI app for macOS and iOS. It displays Upwork's Best Matches and Most Recent job feeds, highlights applicant-count ranges, and collects available client and job details for review.

## Features

- Personalized **Best Matches** and **Most Recent** feeds through Upwork's hosted MCP service.
- Job details with available client location, rating, reviews, contract history, and total spend.
- Markdown-formatted job descriptions in the detail view.
- One-click copy of project and client information.
- Optional AI-generated reply drafts using an API endpoint configured by the user. Drafts can be copied; opening the Upwork listing is a separate user action.
- Per-range proposal highlights for fewer than 5, 5–10, 10–15, 15–20, 20–50, and 50+ proposals. Each range can be green, yellow, red, or unhighlighted.
- macOS polling with local notifications and optional launch at login.
- OAuth credentials and AI API key stored in the platform Keychain.

The app does not submit proposals, send messages, modify contracts, make payments, or invoke Upwork write actions.

## Install on macOS

With [Homebrew](https://brew.sh/) installed:

```sh
brew install --cask Kgym-Hina/upwork-monitor/upwork-monitor
```

The published app has an ad-hoc signature, but no Apple Developer ID signature or notarization. On first launch, macOS may block it; use Finder's Control-click → **Open**, or allow it under **System Settings → Privacy & Security**.

## Connect Upwork

Open **Settings → Connect Upwork** and finish authorization in the browser. The app uses Upwork's hosted MCP server and OAuth 2.1 with dynamic client registration; no manually created Upwork API key is required. OAuth credentials are kept in macOS Keychain. The app reads job feeds and job details, and does not send proposals or messages.

The MCP service may omit or hide some client details. The app displays and copies only fields returned by Upwork; it does not infer missing ratings, history, or spending.

## AI reply drafts

In **Settings → AI reply**, configure an HTTPS API address, model, API key, optional thinking/reasoning options, additional JSON parameters, and a system prompt. The API key is stored in Keychain; the other provider settings are stored locally. Job and client details are sent to the configured AI endpoint only when **Reply with AI** is selected. The app does not provide AI tools that can perform Upwork actions.

## Notifications and platform limits

On macOS, the app periodically checks the two feeds and creates local notifications for newly observed jobs. This is client-side polling, not an Upwork push subscription; keep the app running or enable **Launch at login**. On iOS, refresh is on demand and background delivery is not guaranteed. Installing on a physical iPhone requires signing with an Apple Developer team.

## Build from source

Open `UpworkMonitor.xcodeproj` in Xcode and build the `UpworkMonitor-macOS` or `UpworkMonitor-iOS` scheme. For command-line builds, for example:

```sh
xcodebuild -project UpworkMonitor.xcodeproj \
  -scheme UpworkMonitor-macOS \
  -sdk macosx \
  -configuration Release \
  build
```

## Data handling

The app has no app-owned backend or analytics service. Upwork data is fetched directly from Upwork and held by the app for display, local notifications, and user-requested copying. If AI reply generation is used, the selected job and client details go to the AI endpoint that the user configured; review that provider's privacy terms before enabling it.

Upwork Monitor is an independent project and is not affiliated with or endorsed by Upwork.
