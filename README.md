# Car Status for Škoda

A macOS menu bar app that shows the status of your Škoda at a glance. It reads the data from the [MyŠkoda Public API](https://public.api.connect.skoda-auto.cz/docs).

<p align="center">
  <img src="docs/screenshot.png" alt="The Car Status for Škoda popover showing battery, charging, lock and parking state" width="321">
</p>

## Features

- Battery level, range and charging state (including charge power and plug status)
- Lock state, odometer, vehicle name and licence plate
- Parking position on a map
- Multiple vehicles, each with its own API key; switch between them in the popover
- Background polling, plus a refresh when the popover opens, on manual refresh and after the Mac wakes from sleep
- API keys stored in the macOS Keychain

## Requirements

- macOS 26.0 or later
- Xcode with Swift 6
- A MyŠkoda Public API key and the VIN of each vehicle

## Build

```sh
open SkodaCarStatus.xcodeproj
```

Then run the `SkodaCarStatus` scheme from Xcode. The app has no Dock icon; it lives in the menu bar.

## Download

Grab the latest `SkodaCarStatus-<version>.zip` from [Releases](https://github.com/gempi/skoda-car-status/releases). The app is not notarized, so on first launch right-click it and choose **Open** (or run `xattr -dr com.apple.quarantine "Car Status for Skoda.app"`).

## Releases

Commits to `main` use [Conventional Commits](https://www.conventionalcommits.org) (`feat:`, `fix:`, `feat!:`). [release-please](https://github.com/googleapis/release-please) keeps a release PR up to date; merging it tags the version, creates the GitHub release and attaches the built app.

## Setup

1. Click the menu bar icon and open **Settings**.
2. Choose **Add Vehicle…** and enter the 17-character VIN and your API key.
3. Repeat for more vehicles; with several, switch between them with the name at the top of the popover. A new vehicle starts with the selected vehicle's key, since vehicles in one Škoda account share it; replace it if the vehicle belongs to another account.
4. To change a key, choose the vehicle in Settings and **Edit…**. If other vehicles use the same key, you can update them together. **Remove…** deletes the vehicle and its key from the Keychain.

The key is tested against the API before it is saved. Each vehicle is refreshed at most every 15 minutes, to stay within the API's rate limit of 20 requests per hour per vehicle.

## Disclaimer

Unofficial app. Not affiliated with, endorsed by or sponsored by ŠKODA AUTO a.s. Škoda is a registered trademark of ŠKODA AUTO a.s.
