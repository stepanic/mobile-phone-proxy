# Rotacija mobilne IP adrese na iOS-u (2026-10-01)

Cilj: s Maca (ili bilo kojeg servisa) na zahtjev dobiti **novu javnu IP adresu**
iPhonea koji radi kao proxy. Mreža je Telemach HR mobilna, AS205714. Telefon je
iPhone 15 Pro s iOS 26.4.2, a Mac ga dohvaća preko Tailscalea (`100.71.146.11:8888`).

## Sažetak

| Što | Stanje |
|---|---|
| Airplane mode ≥ ~64 s → nova javna IP | ✅ 7/7 (od toga 5/5 sa 91 s) |
| Airplane mode ≤ 61 s → ista IP | ✅ 4/4 (20, 32, 61, 61 s) |
| Okidač s Maca: `GET /__rotate` → Prečaci po URL-u | ✅ 4/4, ali **samo kad je aplikacija u prvom planu i nije uključen kiosk način** |
| Okidač s Maca: potpisani iMessage → automatizacija → App Intent | ✅ izvan Assistive Accessa; ❌ **u Assistive Accessu nije okinulo** (uzrok nepotvrđen) |
| Guided Access | ❌ blokira otvaranje Prečaca |
| Assistive Access | ✅ vremenska automatizacija i iMessage `MPP-TEST` (bez App Intenta) rade |

## Dvije IP adrese: privatna i javna (CGNAT)

Aplikacija na sučelju `pdp_ip0` vidi samo **privatnu adresu operatera**
(10.x.x.x). Javna adresa (86.33.x.x) nastaje tek na Telemachovom CGNAT-u i
vidi se samo izvana. Zato aplikacija javnu adresu dohvaća sama
(`PublicIP.swift`, `api.ipify.org` preko socketa vezanog na mobilno sučelje).

Kad se javna adresa promijenila, promijenila se i privatna. Kad je ostala
ista, ostala je i privatna. Operater, dakle, nakon kratkog prekida vraća istu
PDP sesiju.

## Mjerenja: koliko dugo Airplane mode

| Prekid | Način | Javna IP prije → poslije |
|---|---|---|
| ~20 s | ručno | ista |
| ~32 s | ručno | ista |
| 61 s | prečac | `86.33.88.39` → ista |
| ~64 s | ručno | `86.33.83.7` → `86.33.95.153` |
| >77 s | ručno | `86.33.87.19` → `86.33.83.7` |
| 91 s | prečac | `86.33.88.39` → `86.33.82.230` |
| 91 s | prečac | `86.33.82.230` → `86.33.86.151` |
| 91 s | prečac | `86.33.86.151` → `86.33.86.62` |
| 91 s | prečac | `86.33.86.62` → `86.33.90.207` |
| 91 s | prečac | `86.33.90.207` → `86.33.82.18` |

Granica je između 61 i ~64 s. **91 s je radna vrijednost**: s Maca jedna
rotacija traje oko 97 s, a preko iMessagea oko 105–112 s.

## Arhitektura okidača

```mermaid
flowchart LR
  subgraph Mac
    S[macos/rotate-ip.sh]
  end
  subgraph iPhone
    A[Mobile Phone Proxy app]
    SC1["Prečac: Rotate IP<br/>Airplane ON → Wait 91 s → OFF"]
    SC2["Prečac: Rotate IP Secure<br/>Verify Rotate Command → If → Rotate IP"]
    AU["Automatizacija:<br/>Message contains MPP-ROTATE"]
  end
  S -- "GET /__rotate (Tailscale)" --> A
  A -- "shortcuts://x-callback-url/run-shortcut" --> SC1
  SC1 -- "x-success: mobilephoneproxy://" --> A
  S -- "iMessage: MPP-ROTATE v1 ts nonce hmac" --> AU
  AU --> SC2
  SC2 -- "App Intent u procesu aplikacije" --> A
  SC2 --> SC1
```

### A) URL okidač (`/__rotate`)

- Aplikacija može otvoriti drugu aplikaciju **samo dok je u prvom planu**.
  Inače `/__rotate` vraća 409.
- **Guided Access** to blokira (test: `rotation aborted`). Opasnosti nema:
  Airplane mode se ne upali i telefon ostaje dostupan.
- U **Assistive Access** se aplikacija **Prečaci ne može dodati** (nema je na
  popisu), pa ovaj put tamo ne postoji.

### B) Potpisani iMessage

Format: `MPP-ROTATE v1 <unix-ts> <nonce> <hex HMAC-SHA256(secret, "MPP-ROTATE|v1|ts|nonce")>`

- Prečaci ne znaju računati HMAC, pa provjeru radi App Intent **Verify Rotate
  Command** (`VerifyRotateCommandIntent.swift`, `RotateAuth.swift`). Provjera
  usporedbom u konstantnom vremenu, prozor od 300 s plus 60 s pomaka sata,
  jednokratni nonce (troši se tek nakon ispravnog potpisa).
- Ključ: `GET /__pair` samo u 2-minutnom prozoru koji se otvara tipkom „Pair
  Mac" u aplikaciji. Na iOS-u je u Keychainu (`AfterFirstUnlockThisDeviceOnly`),
  na Macu u login keychainu (service `mobile-phone-proxy-rotate`). Ključ je
  **preživio brisanje i ponovnu instalaciju aplikacije**.
- Okidač „Message contains" reagira i na poruku s **istog Apple ID-a**, pa
  drugi račun ne treba. Kašnjenje od slanja do pada mreže bilo je 16–54 s.
- Mac šalje preko `osascript` → Messages. Mac čita poslane poruke iz
  `~/Library/Messages/chat.db` (tekst je u `attributedBody`), što je korisno
  za provjeru je li poruka isporučena.

## Zamke koje su koštale vremena

1. **Akcija iz aplikacije se ne pojavljuje u Prečacima** dok se ne promijeni
   `CFBundleVersion`. Svi raniji buildovi imali su `1`. Sada `project.yml`
   koristi `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION`, a za svaki build za
   uređaj treba povećati `CURRENT_PROJECT_VERSION`. Uz to postoji i
   `AppShortcutsProvider`. Na kraju je trebalo i obrisati pa ponovno
   instalirati aplikaciju.
2. **App Intent se vidi u Prečacima, ali ne i u uredniku automatizacija.**
   Zaobilazno rješenje je običan prečac „Rotate IP Secure" koji automatizacija
   pokreće s ulazom Shortcut Input.
3. **„Prečac pokreće drugi prečac" traži jednokratnu potvrdu.** Prva prava
   iMessage rotacija je tiho zapela na tom upitu. Nakon „Always Allow" radi bez
   dodira.
4. **`handle` je rezervirana riječ** u AppleScript rječniku aplikacije
   Messages: `on run {handle, …}` puca s `Can't get handle (-1728)`.
5. **Origin-form zahtjev** (`GET /__rotate` bez apsolutnog URI-ja) se prije
   proslijeđivao natrag samom proxyju. Sada ga aplikacija obrađuje lokalno.
6. **Instalacija preko Tailscalea nije moguća**: CoreDevice/devicectl traži
   Bonjour na istoj mreži, a RoamRun i iphone-tailnet-bridge trebaju prvo
   uparivanje na istoj mreži. Radi **Ad Hoc** (tim `6SCK58757K` je plaćeni, a
   UDID telefona je u profilu) preko privremenog `cloudflared` quick tunela s
   `itms-services` manifestom. Link se telefonu može poslati iMessageom.
   **Za lokalni HTTP server uvijek uzmi provjereno slobodan port**: port 8765
   je bio zauzet tuđim CRM UI-jem, koji je zato ~1–2 min bio javno izložen.
7. Jedna neuspjela provjera (zastoj DERP relaya) nije Airplane mode.
   `rotate-ip.sh` sada traži dvije neuspjele provjere zaredom.

## Odbačeno

- **Privatni API `RadiosPreferences.setAirplaneMode:`**: treba Appleov privatni
  entitlement koji se ne može dobiti ni u Ad Hoc ni u Enterprise profilu.
  Ostaje samo jailbreak ili TrollStore, a ni jedno ni drugo ne postoji za iOS 26.
- **Guided Access kao kiosk**: blokira otvaranje Prečaca.
- **Single App Mode**: traži nadzirani uređaj (MDM), dakle reset telefona.

## Otvoreno

- **Potpisani iMessage u Assistive Accessu nije okinuo** (17:44, telefon nije
  pao 5 min). Log aplikacije nije pročitan, pa se ne zna je li App Intent
  odbio poruku, nije se pokrenuo, ili je zapeo neki nevidljivi upit. Sljedeći
  korak je pročitati log (vidi `/__log` niže). Moguće rješenje je da sve akcije
  budu u jednom prečacu, bez „Run Shortcut".
- **`/__log` endpoint** i `lastRotateCommand` u `/__status` još ne postoje.
  Log aplikacije trenutno se vidi samo na ekranu telefona.
- **Ponovno slanje u `rotate-ip.sh --imessage`**: ako telefon ne padne u roku
  od ~60 s, poslati novu poruku s novim nonceom.
- **Vlastiti relay servis** (ideja korisnika): Cloudflare Worker ili mali
  Node.js servis na koji bilo koji posao u oblaku (Worker, Lambda) pošalje
  potpisani signal, a aplikacija ga povlači. Ograničenje koje se mora riješiti:
  **aplikacija ne može sama upaliti Airplane mode**. Može samo otvoriti
  Prečace po URL-u (u prvom planu, ne u Assistive/Guided Accessu) ili se
  osloniti na automatizaciju. U Assistive Accessu za sada su dokazane samo
  automatizacije (vrijeme, poruka), pa relay mora završiti okidačem koji
  automatizacija vidi, npr. iMessageom koji relay šalje.
- **Android** to može bez ovih zaobilaznica: Shizuku (ovlasti na razini ADB-a,
  bez roota) → `cmd connectivity airplane-mode enable/disable` iz same
  aplikacije, a kiosk se dobije pinanjem ekrana. Na uređaju još nije isprobano.

## Vezani dokumenti

- `README.md` → *Remote (phone not on your WiFi)*
- `macos/rotate-ip.sh` (`--help`)
