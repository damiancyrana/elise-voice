# Elise Voice — know-how utrzymaniowe

## Zakres produktu

Elise Voice wykonuje jeden przepływ: `⌥Space` rozpoczyna dyktowanie, lokalny
Whisper przepisuje polską mowę, a wynik trafia do wcześniej aktywnego pola.
Ponowne `⌥Space`, 20 sekund ciszy albo limit 5 minut kończą nagrywanie.

Głos, hałas i dźwięk odtwarzany przez komputer nie mogą zmieniać stanu
aplikacji. Aktywacja głosowa jest poza kontraktem produkcyjnym.

## Wymagania

- Apple Silicon i macOS 14 lub nowszy,
- Xcode Command Line Tools ze Swift 6,
- około 1,5 GB wolnego miejsca przed pierwszym pobraniem modelu,
- `ffmpeg` wyłącznie do testów audio,
- Internet wyłącznie podczas pierwszego pobrania Large v3.

Zależność WhisperKit jest przypięta do dokładnej wersji w `Package.swift`, a
pełne rozstrzygnięcie znajduje się w `Package.resolved`.

## Budowanie i instalacja prywatna

```bash
./scripts/check-production.sh
./scripts/install.sh
```

Pierwsza komenda nie modyfikuje `/Applications`. Druga atomowo podmienia
aplikację, zachowuje poprzednią wersję do czasu powodzenia operacji, weryfikuje
podpis, przypina ikonę do Docka i uruchamia program. Prywatny build ma stabilny
podpis ad-hoc i nie jest paczką do publicznego rozpowszechniania.

## Uprawnienia

Przy pierwszym uruchomieniu należy przyznać:

1. Mikrofon — tylko do dyktowania rozpoczętego przez `⌥Space`.
2. Dostępność — do wpisania tekstu w innej aplikacji.

Elise musi być uruchamiana jako `/Applications/EliseVoice.app`, nie jako binarka
ze `.build`. W razie przebudowy z inną tożsamością TCC można zresetować zgodę:

```bash
tccutil reset Microphone com.elisevoice.app
tccutil reset Accessibility com.elisevoice.app
open /Applications/EliseVoice.app
```

Reset wymaga ponownego ręcznego zatwierdzenia zgód.

## Modele

Produkcyjna aplikacja używa jednego modelu: Whisper Large v3. Nie jest on
wersjonowany w repozytorium; WhisperKit pobiera
`large-v3-v20240930_626MB` do Application Support. Znacznik gotowości powstaje
dopiero po poprawnym przygotowaniu modelu, a niepełny katalog trafia do
kwarantanny.

Pakiet nie może zawierać:

- `EliseWakeWord.mlmodel`,
- `ElisePersonalWakeVerifier.mlmodel`.

Kod produkcyjny nie inicjalizuje ich i `AudioCaptureService` nie udostępnia
punktu do podłączenia detektora. Dawne źródła, próbki i skrypty treningowe są
wyłącznie materiałem eksperymentalnym; nie wolno dodawać ich do bramy wydania
bez nowej decyzji produktowej i niezależnej walidacji na żywo.

Whisper Tiny nie jest używany. Kod migracyjny usuwa jego dawne katalogi z
Application Support.

## Zestaw kontroli

`scripts/check-production.sh` jest bramką wydania i uruchamia kolejno:

1. kompilację z ostrzeżeniami jako błędami, testy polityk i lint metadanych,
2. regresję transkrypcji 99,5-sekundowego polskiego nagrania,
3. build release, kontrolę arm64, wersji, podpisu i integralności bundle'a,
4. kontrolę braku obu modeli aktywacji głosowej w pakiecie.

Dodatkowy audyt ostrzeżeń:

```bash
swift build -c release -Xswiftc -warnings-as-errors
```

Benchmark liczby workerów:

```bash
./scripts/benchmark-asr.sh
```

## Diagnostyka

Logi aplikacji można śledzić bez ujawniania tekstu ani audio:

```bash
log stream --style compact --level debug \
  --predicate 'process == "EliseVoice" AND subsystem == "com.elisevoice.app"'
```

Kategorie produkcyjne obejmują cykl życia, audio, transkrypcję, model i
wklejanie. Po osiągnięciu stanu `ready` log nie powinien pokazać uruchomienia
mikrofonu. `Microphone stream started` może wystąpić dopiero po `⌥Space`, a
`Microphone stream stopped` przed transkrypcją. W produkcji nie powinny pojawić
się logi `ELISE keyword detected` ani `Personal acoustic verification`.

Zainstalowana aplikacja nigdy nie loguje rozpoznanego tekstu.

## Typowe awarie

- Brak Elise na liście Mikrofon: uruchomić zainstalowany bundle i użyć pozycji
  „Ustawienia mikrofonu…” w menu.
- Dostępność jest zaznaczona, ale wklejanie nie działa: usunąć starą pozycję
  TCC, zresetować zgodę i dodać aktualny `/Applications/EliseVoice.app`.
- Panel pokazuje `START`: trwa pierwsze pobranie lub przygotowanie Large v3.
- `⌥Space` nie rozpoczyna nagrywania: sprawdzić status aplikacji, zgodę na
  mikrofon i czy skrót nie został przejęty przez inną aplikację.
- Zmiana mikrofonu w trakcie dyktowania: odczekać automatyczną odbudowę
  strumienia; poza dyktowaniem mikrofon pozostaje wyłączony.
- Brak wklejenia po zmianie aplikacji: tekst powinien pozostać w schowku; jest
  to zabezpieczenie przed wpisaniem do niewłaściwego pola.

## Publiczne wydanie

Wymagane są certyfikat `Developer ID Application` i zapisany profil notarytool:

```bash
ELISE_PRODUCTION=1 \
ELISE_SIGN_IDENTITY='Developer ID Application: …' \
./scripts/build-app.sh

ELISE_SIGN_IDENTITY='Developer ID Application: …' \
ELISE_NOTARY_PROFILE='profil-notarytool' \
./scripts/notarize.sh
```

## Zasady zmian

- Callback Core Audio nie może wykonywać inferencji, alokacji dużych tablic ani
  blokującego I/O.
- Żaden log nie może zawierać audio ani dyktowanego tekstu.
- Tylko `⌥Space` może przełączyć stan `ready` na `recording`.
- Mikrofon musi być wyłączony w `ready`, `preparing`, `transcribing` i `failed`.
- Modele aktywacji głosowej nie mogą trafić do produkcyjnego bundle'a.
- Zmiana identyfikatora bundle lub sposobu podpisu wymaga planu migracji TCC.
- Nowy build nie jest gotowy do instalacji, dopóki nie przejdzie
  `scripts/check-production.sh`.
