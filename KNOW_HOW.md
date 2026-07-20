# Elise Voice — know-how utrzymaniowe

## Zakres produktu

Elise Voice wykonuje tylko jeden przepływ: rozpoczęcie dyktowania przez
`⌥Space` lub — w sesji podtrzymywanej aktywnością użytkownika — ILIS/ILIZ/ELAJS, lokalną
transkrypcję po polsku i wklejenie do wcześniej aktywnego pola. Zatrzymanie
następuje po ponownym `⌥Space`, 20 s ciszy albo po osiągnięciu limitu 5 minut.
Rozbudowa poza ten kontrakt wymaga świadomej decyzji produktowej.

## Wymagania

- Apple Silicon i macOS 14 lub nowszy,
- Xcode Command Line Tools ze Swift 6,
- około 1,5 GB wolnego miejsca przed pierwszym pobraniem modelu,
- `ffmpeg` wyłącznie do generowania danych i testów audio,
- dostęp do Internetu wyłącznie podczas pierwszego pobrania Large v3.

Zależność WhisperKit jest przypięta do dokładnej wersji w `Package.swift`, a
pełne rozstrzygnięcie znajduje się w `Package.resolved`.

## Budowanie i instalacja prywatna

```bash
./scripts/check-production.sh
./scripts/install.sh
```

Pierwsza komenda nie modyfikuje `/Applications`. Druga atomowo podmienia
aplikację, zachowuje poprzednią wersję do czasu powodzenia operacji, weryfikuje
podpis, przypina ikonę do Docka i uruchamia program. Prywatny build jest
podpisany stabilnym podpisem ad-hoc. Nie jest paczką do publicznego
rozpowszechniania.

## Uprawnienia

Przy pierwszym uruchomieniu należy przyznać:

1. Mikrofon — lokalna analiza hasła i dyktowania.
2. Dostępność — wpisanie tekstu do innej aplikacji.

Elise musi być uruchamiana jako `/Applications/EliseVoice.app`, nie jako binarka
ze `.build`. W razie przebudowy z inną tożsamością TCC można zresetować zgodę i
uruchomić aplikację ponownie:

```bash
tccutil reset Microphone com.elisevoice.app
tccutil reset Accessibility com.elisevoice.app
open /Applications/EliseVoice.app
```

Reset usuwa zgodę, więc wymaga ponownego ręcznego zatwierdzenia w Ustawieniach
systemowych.

## Modele

W bundle’u znajdują się dwa bardzo małe modele Core ML:

- `EliseWakeWord.mlmodel` — ogólny generator kandydatów,
- `ElisePersonalWakeVerifier.mlmodel` — dokładny model właściciela.

Whisper Large v3 nie jest wersjonowany w repozytorium. Przy pierwszym starcie
WhisperKit pobiera `large-v3-v20240930_626MB` do Application Support. Znacznik
gotowości powstaje dopiero po poprawnym przygotowaniu modelu; niepełny katalog
jest przenoszony do kwarantanny.

Whisper Tiny nie jest używany. Kod migracyjny usuwa jego dawne katalogi z
Application Support, dlatego wzmianka `legacy` w `ModelStorage` jest aktywną
logiką migracji, a nie martwym kodem.

## Kalibracja głosu właściciela

Kalibracja jest jawna i jednorazowa:

```bash
./scripts/run-personal-calibration.sh
./scripts/train-wake-word.sh
./scripts/check-personal-wake-verifier.sh
```

Należy mówić normalnym głosem, z typowej odległości od mikrofonu. Skrypt prosi o
24 warianty hasła i 30 negatywów. Zbiór jest dzielony deterministycznie na
trening, walidację i test. Nie należy trenować z rozmów ani odtwarzać próbek
przez głośnik.

Surowe próbki pozostają tylko w `.build/wake-word-personal` i są ignorowane
przez Git. Nie rosną w czasie, bo aplikacja nie dopisuje nowych plików. Po
zaakceptowaniu modelu można je usunąć; zachowanie ich umożliwia powtórny trening
bez ponownego nagrywania. Model w `Resources/Models` nie pozwala odtworzyć
oryginalnych wypowiedzi.

## Zestaw kontroli

`scripts/check-production.sh` jest bramką wydania i uruchamia kolejno:

1. kompilację, testy polityk, lint plist/entitlements i kontrolę braku Whisper
   Tiny,
2. regresję ogólnego keyword spottera na korpusie trudnych negatywów,
3. produkcyjny osobisty weryfikator na wszystkich 54 próbkach z symulowanym
   kontekstem bufora,
4. Large v3 dla ILIS/ELAJS kontra Lis/Elisa,
5. transkrypcję 99,5 s z kontrolą początku i końca,
6. build release, architekturę arm64, wersję, obecność zasobów i podpis.

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

Kategorie obejmują cykl życia, audio, keyword spotting, personalny weryfikator,
transkrypcję, model i wklejanie. Signposty pozwalają mierzyć start mikrofonu,
transkrypcję, sygnał gotowości i utracone bufory w Instruments.

Do inspekcji dokładnego tekstu zwracanego przez zapasowy weryfikator służy
wyłącznie deweloperski tryb:

```bash
swift run EliseVoiceASRCheck --inspect-wake próbka.wav
```

Zainstalowana aplikacja nigdy nie loguje rozpoznanego tekstu.

## Typowe awarie

- Brak Elise na liście Mikrofon: uruchomić zainstalowany bundle i użyć pozycji
  „Ustawienia mikrofonu…” w menu.
- Dostępność jest zaznaczona, ale wklejanie nie działa: usunąć starą pozycję TCC,
  zresetować zgodę i dodać aktualny `/Applications/EliseVoice.app`.
- Panel pokazuje `START`: trwa pierwsze pobranie lub przygotowanie Large v3.
- Mikrofon po starcie jest wyłączony: pierwsze `⌥Space` dyktuje i uzbraja
  30-minutowy nasłuch. Jeżeli ma wyłączać się od razu po każdym dyktowaniu,
  wyłączyć głosowe wybudzanie w menu.
- Zmiana mikrofonu lub wybudzenie: odczekać automatyczną odbudowę strumienia;
  kolejne niepowodzenia mają kontrolowany backoff.
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

Skrypt notaryzacji tworzy archiwum, wysyła je do Apple, stapluje ticket i
wykonuje końcową ocenę Gatekeepera. Brak certyfikatu lub profilu jest zależnością
zewnętrzną, nie powinien być obchodzony zmianą skryptów.

## Zasady zmian

- Callback Core Audio nie może wykonywać inferencji, alokacji dużych tablic ani
  blokującego I/O.
- Żaden log nie może zawierać audio ani dyktowanego tekstu.
- Każda zmiana progów hasła musi przejść zarówno korpus ogólny, jak i 54 próbki
  personalne.
- Zmiana czasu sesji musi zachować kontrakt: start i blokada oznaczają mikrofon
  wyłączony, `⌥Space` uzbraja, aktywność HID podtrzymuje, a 30 minut bezczynności
  rozbraja.
- Zmiana identyfikatora bundle lub sposobu podpisu wymaga planu migracji TCC.
- Nowy build nie jest gotowy do instalacji, dopóki nie przejdzie
  `scripts/check-production.sh`.
