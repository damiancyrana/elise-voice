# Architektura produkcyjna Elise Voice

## Kontrakt interakcji

Po starcie mikrofon jest wyłączony. `⌥Space` rozpoczyna nagrywanie i uzbraja
30-minutową sesję wybudzania głosem. W jej trakcie nagrywanie uruchamia kolejne
`⌥Space` albo lokalnie wykryte słowo „ELISE”. Aktywność klawiatury, myszy lub
Elise podtrzymuje sesję. Kończy je ponowne `⌥Space`, 20 sekund ciągłej ciszy lub twardy limit
5 minut. Hasło i sygnał gotowości są analizowane przed rozpoczęciem właściwego
bufora, więc nie trafiają do dyktowanego tekstu.

## Komponenty

1. `GlobalHotKey` rejestruje `⌥Space` bez przejmowania fokusu.
2. `AudioCaptureService` utrzymuje co najwyżej jeden strumień `AVAudioEngine`.
   Callback czasu rzeczywistego wykonuje nieblokującą kopię do jednej z sześciu
   wcześniej zaalokowanych ramek. Resampling do 16 kHz mono, RMS, zapis i
   analiza działają na ograniczonej kolejce poza callbackiem. Bufor nagrania
   jest typem referencyjnym, więc nie kopiuje całej rosnącej tablicy. Heartbeat
   oraz licznik odrzuconych ramek wykrywają przeciążenie i zawieszony strumień.
3. `WakeWordDetector` używa `SoundAnalysis` i dedykowanego modelu Core ML
   `EliseWakeWord`. Tania bramka poziomu dźwięku przechowuje 560 ms pre-roll i
   otwiera analizę na czas mowy oraz 1,25 s ogona. Nakładające się co 200 ms
   okna, dwa zgodne wyniki oraz cooldown ograniczają fałszywe wybudzenia.
   Mocne wyniki mogą być rozdzielone krótkim oknem przejściowym między
   sylabami. Nawet pojedynczy wynik o bardzo wysokiej pewności nie wystarcza,
   ponieważ w praktyce takie piki mogą powodować odgłosy klawiatury i pokoju.
   Kandydat przechodzi drugi etap na nadpisywanym buforze 2,4 s. Osobny,
   kilkukilobajtowy model akustyczny, wytrenowany tylko na głosie właściciela,
   analizuje ostatnią wyspę mowy po wyrównaniu jej do jednosekundowego okna
   użytego podczas kalibracji. Jeśli nie potwierdzi wzorca, zapasowo
   dokładną formę krótkiego transkryptu sprawdza Large v3. Dopiero zgodne
   ILIS/ILIZ/ELAJS przechodzi do koordynatora; `Lis`, `Elisa` i zwykłe zdania są
   odrzucane bez pokazania okna nagrywania.
4. `DictationCoordinator` jest maszyną stanów i właścicielem cyklu mikrofonu.
   Oddziela trwałą preferencję wybudzania od ulotnego uzbrojenia sesji. Timer
   sprawdza czas od ostatniej interakcji Elise oraz dowolnego zdarzenia HID;
   mikrofon zatrzymuje dopiero 30 minut rzeczywistej bezczynności. Blokada i
   uśpienie kończą sesję natychmiast. Strumień jest odbudowywany po zmianie konfiguracji sprzętu
   tylko dla nadal aktywnej sesji. Błędy przejściowe mają wykładniczy backoff i
   wracają do `ready`; zawieszona transkrypcja ma watchdog i jednorazową
   odbudowę modelu. Użytkownik może całkowicie wyłączyć głosowe wybudzanie.
5. `TranscriptionService` wymusza język `pl`. Audio dłuższe od okna Whispera
   dzieli przez VAD i dekoduje z trzema workerami — wartością wybraną pomiarem
   99,5-sekundowego polskiego nagrania na docelowym M4 Pro. Model jest stale
   rozgrzany, lecz może zostać zwolniony po krytycznej presji pamięci.
6. `RecordingWindowController` wyświetla nieaktywujący panel SwiftUI/AppKit pod
   notchem. `TimelineView` istnieje wyłącznie podczas widocznej animacji.
7. `TextInserter` zapamiętuje proces i dokładny element AX na początku nagrania.
   Najpierw próbuje bezpośredniej edycji AX, potem kontrolowanego `⌘V`. Jeśli
   fokus się zmienił, nie wkleja tekstu w przypadkowe miejsce i pozostawia go w
   schowku. Sukces bez rzeczywistej zmiany wartości jest wykrywany i kierowany
   do ścieżki zapasowej. Pola `AXSecureTextField` są zawsze odrzucane, a
   awaryjna ścieżka schowka nie blokuje zakończenia dyktowania przez pełną
   sekundę.
8. `LaunchAtLoginService` używa `SMAppService.mainApp`.

## Modele

- Transkrypcja: `openai/whisper-large-v3`, artefakt Core ML
  `openai_whisper-large-v3-v20240930_626MB`.
- Hasło: własny `MLSoundClassifier` z Apple Audio Feature Print, etykiety
  `elise`/`background`, okno 1 s. Dane syntetyczne są rozdzielone głosami na
  trening, walidację i test. Drugi klasyfikator powstaje z jawnie nagranych
  próbek właściciela i trudnych negatywów. Do aplikacji trafiają wyłącznie wagi
  modeli, bez próbek audio.

Whisper Tiny nie jest częścią aplikacji ani ścieżki awaryjnej. Przy migracji jego
stare katalogi są usuwane. Large v3 jest ładowany i rozgrzewany podczas startu,
ale wykonuje inferencję tylko po zakończeniu dyktowania albo dla rzadkiego
kandydata, którego nie potwierdził osobisty klasyfikator.

## Prywatność i diagnostyka

- Nagranie dyktowania istnieje wyłącznie w RAM; aplikacja nie tworzy historii.
- Klasyfikator hasła działa lokalnie. Nadpisywany bufor w RAM przechowuje
  najwyżej trzy sekundy do weryfikacji kandydata i nigdy nie trafia na dysk.
- Mikrofon jest wyłączony po uruchomieniu, po 30 minutach bez użycia Elise oraz
  po zablokowaniu lub uśpieniu komputera. Ponowne `⌥Space` uzbraja nową sesję.
- Sieć jest potrzebna tylko do pierwszego pobrania Large v3 z Hugging Face.
- Logi `OSLog` zawierają stany, czasy i liczbę próbek, nigdy audio ani tekst.
- `OSSignposter` mierzy start mikrofonu, sygnał gotowości, transkrypcję,
  wklejanie i utracone bufory bez przechowywania treści.
- Przed pobraniem jest sprawdzane wolne miejsce, a niekompletny katalog modelu
  trafia do kwarantanny.
- Próbki kalibracyjne są tworzone wyłącznie przez jawnie uruchomiony skrypt,
  pozostają w ignorowanym przez Git katalogu `.build` i nie są odczytywane przez
  zainstalowaną aplikację. Nie ma automatycznego uczenia na dyktowaniu.

## Dystrybucja

Domyślny skrypt tworzy arm64 bundle z Hardened Runtime i stabilnym podpisem
ad-hoc dla prywatnej instalacji. Tryb `ELISE_PRODUCTION=1` odrzuca podpis lokalny
i wymaga tożsamości `Developer ID Application`. `scripts/notarize.sh` wysyła
archiwum przez `notarytool`, stapluje ticket i wykonuje końcową ocenę
Gatekeepera. Podpis Developer ID korzysta z wymagań wygenerowanych przez Apple,
wiążących aplikację z Team ID; lokalny wymóg po samym bundle ID nie jest używany
w wydaniu publicznym.
