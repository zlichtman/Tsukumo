# Muse Gadget SDK provenance

`Sources/TsukumoMuse/` is a Swift port of parts of Meta's [Muse Gadget SDK](https://github.com/facebookincubator/muse-gadget-sdk) (Linux Device SDK, `linux/src/musegadget/`, read at commit `b139b45064b4dcecf7bfe97e75bc7f99c10c28b6`, October 5, 2026). Copyright (c) Meta Platforms, Inc. and affiliates. Licensed under the Apache License, Version 2.0 (http://www.apache.org/licenses/LICENSE-2.0); the ported files keep their protocol constants, field numbers, checks, and behavior, and were rewritten in Swift on Apple's CryptoKit, CoreBluetooth, Network, and Foundation. No SDK code is vendored and TsukumoKit has no package dependencies.

What was ported, and from where:

| TsukumoMuse | From the SDK | Changes |
|---|---|---|
| `MuseEnvelope.swift` | `noise/_proto.py`, `noise/envelope.py` | Hand-written protobuf in Swift |
| `MuseNoise.swift` | `noise/noise_xx.py`, `noise/framing.py`, `noise/transport.py` | CryptoKit's Curve25519, AES-GCM, SHA-256, and HMAC; the same pattern (`Noise_XX_25519_AESGCM_SHA256`), empty prologue, low-order checks, and nonce ceiling |
| `MusePairing.swift` | `pairing.py`, `ble_framing.py` | CryptoKit's P-256, HKDF, and AES-GCM; community pairing v5 with `confirm_app` only, as the SDK; a six-digit code from the transcript for the owner's confirmation |
| `MuseSetup.swift` | `ble_setup.py` | A dispatch queue and locks in place of the worker thread; the Wi-Fi scan offers "Use current connection" without reading the network's name; the owner must allow the phone on the Mac before `pairing_confirmed` or provisioning |
| `MusePeripheral.swift` | `ble_server.py` | CoreBluetooth's `CBPeripheralManager` in place of BlueZ over D-Bus; same service and characteristic UUIDs. macOS can't advertise the SDK's manufacturer-data flag or drop a central |
| `MuseIdentity.swift` | `identity.py`, `config.py` | The identity in the app's folder; the SDK token and device tokens in the Keychain; registers as `platform: "macos"` and falls back to the SDK's own Linux values only if Muse refuses that |
| `MuseAPI.swift` | `muse_api.py` | URLSession behind a protocol; only the SDK's own two hosts, `api.muse.ai` and `hatch.metaaivm.com` (`MuseEndpoints`, from `API_BASE` and `DEFAULT_NOISE_HOST`), and no redirects |
| `MuseLink.swift` | `link_client.py` | URLSession's WebSocket; Swift concurrency |
| `MuseService.swift` | `service.py` | Swift concurrency; no local socket |
| `MuseCommands.swift` | `executor.py` (the command-spec shape only) | Tsukumo's own commands; `system.run`, `file.read`, `file.write`, and `device.ota` are never offered |

A copy of this notice with the full Apache-2.0 license text ships inside the app (`Sources/TsukumoMuse/Resources/Muse-NOTICE.txt`, in the `TsukumoKit_TsukumoMuse` bundle; Settings, KemoSabe, Muse, License…).

Not covered and not used: the Apache License doesn't cover the SDK's Jollybot avatar (`esp32/avatar/`); Tsukumo doesn't include or show it. Nothing from the ESP32 firmware is included.

Using a gadget needs the person's own SDK token from https://gadgets.muse.ai/settings/sdk-tokens, under the Gadget SDK Terms (https://gadgets.muse.ai/sdk-terms): tokens are personal, for personal non-commercial use, and are never built into Tsukumo or shared; each owner pastes their own. Tsukumo isn't made or endorsed by Meta. Muse is Meta's; "Hatch" names that remain (the `hatch_link` model, `hatch-link` pairing labels, `hatch.metaaivm.com`, the `hatch_refresh:` prefix) are the server's and the Muse app's, kept as the SDK keeps them.
