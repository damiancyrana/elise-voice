# Architektura produkcyjna Elise Voice

## Kontrakt interakcji

Jedynym zdarzeniem rozpoczynającym dyktowanie jest globalny skrót `⌥Space`.
Ponowne `⌥Space`, 20 sekund ciągłej ciszy albo limit 5 minut kończą nagrywanie.
Mikrofon nie działa w stanie gotowości i nie reaguje na głos, słowo kluczowe,
hałas ani dźwięk odtwarzany przez komputer.

Sygnał gotowości jest odtwarzany przed rozpoczęciem właściwego bufora, dlatego
nie trafia do dyktowanego tekstu. Po zakończeniu nagrywania mikrofon jest
zatrzymywany przed uruchomieniem transkrypcji.

## Komponenty

1. `GlobalHotKey` rejestruje `⌥Space` bez przejmowania fokusu i odnawia
   rejestrację po wybudzeniu systemu lub przywróceniu sesji użytkownika.
   Nieudane odnowienie jest ponawiane z narastającym opóźnieniem, a menu
   zawiera niezależny od Carbona wyzwalacz dyktowania.
2. `DictationCoordinator` jest maszyną stanów i jedynym właścicielem cyklu
   mikrofonu. Uruchamia strumień wyłącznie przy przejściu z `ready` do
   `recording`, a zatrzymuje go przed `transcribing`, po błędzie, uśpieniu lub
   blokadzie. Skrót otrzymany podczas przygotowania albo transkrypcji zachowuje
   żądanie kolejnego dyktowania. Zmiana urządzenia audio powoduje odbudowę
   strumienia tylko wtedy, gdy dyktowanie nadal trwa.
3. `AudioCaptureService` utrzymuje co najwyżej jeden strumień `AVAudioEngine`.
   Callback czasu rzeczywistego wykonuje nieblokującą kopię do jednej z sześciu
   wcześniej zaalokowanych ramek. Resampling do 16 kHz mono, RMS i zapis
   nagrania działają na ograniczonej kolejce poza callbackiem. Heartbeat oraz
   licznik odrzuconych ramek wykrywają przeciążenie i zawieszony strumień.
   Serwis nie ma wejścia do podłączenia detektora słowa kluczowego ani bufora
   ciągłego nasłuchu.
4. `TranscriptionService` wymusza język `pl`. Audio dłuższe od okna Whispera
   dzieli przez VAD i dekoduje z trzema workerami — wartością wybraną pomiarem
   99,5-sekundowego polskiego nagrania na docelowym M4 Pro. Zawieszona
   transkrypcja ma watchdog i jednorazową odbudowę modelu.
5. `RecordingWindowController` wyświetla nieaktywujący panel SwiftUI/AppKit pod
   notchem. `TimelineView` istnieje wyłącznie podczas widocznej animacji.
6. `TextInserter` ogranicza czas zapytań Accessibility do `0,5 s`, a
   przeszukiwanie drzewa elementów do `0,3 s`, żeby zawieszona aplikacja na
   pierwszym planie nie blokowała głównego wątku. Zapamiętuje aktywną aplikację
   i dokładny element AX na początku nagrania. Obsługuje elementy webowe udostępniane przez proces
   renderera przeglądarki. Najpierw próbuje bezpośredniej edycji AX, potem
   kontrolowanego `⌘V`. Pola `AXSecureTextField` są zawsze odrzucane. Jeśli
   fokus się zmienił, tekst pozostaje w schowku zamiast trafić do przypadkowego
   miejsca. Gdy przeglądarka nie wystawia aktywnego elementu AX, fallback jest
   dostępny tylko dla rozpoznanych przeglądarek i wymaga tego samego aktywnego
   okna.
7. `LaunchAtLoginService` używa `SMAppService.mainApp`.

## Modele

Produkcyjna aplikacja korzysta wyłącznie z transkrypcji
`openai/whisper-large-v3`, artefakt Core ML
`openai_whisper-large-v3-v20240930_626MB`. Model jest ładowany i rozgrzewany
podczas startu, ale wykonuje inferencję dopiero po zakończeniu dyktowania.

Gdy komplet plików modelu i tokenizer są na dysku, `ModelStorage` wskazuje ich
katalog, a `TranscriptionService` przekazuje go WhisperKitowi jako `modelFolder`
z wyłączonym pobieraniem. Zwykły start nie wykonuje wtedy żadnego zapytania
sieciowego i działa bez łączności. Nieudane przygotowanie jest ponawiane z
narastającym opóźnieniem, a wybudzenie systemu ponawia je natychmiast.

Modele aktywacji `EliseWakeWord` i `ElisePersonalWakeVerifier` nie są kopiowane
do bundle'a, przygotowywane ani wywoływane. Ich dawne źródła i narzędzia
treningowe mogą służyć wyłącznie do analizy historycznych eksperymentów. Nie są
elementem architektury produkcyjnej.

Whisper Tiny również nie jest częścią aplikacji ani ścieżki awaryjnej. Przy
migracji jego stare katalogi są usuwane.

## Prywatność i diagnostyka

- Mikrofon działa tylko podczas jawnie rozpoczętego dyktowania.
- Nagranie istnieje wyłącznie w RAM; aplikacja nie tworzy historii.
- Nie ma kroczącego bufora oczekiwania, rozpoznawania słowa kluczowego ani
  automatycznego uczenia głosu.
- Sieć jest potrzebna tylko do pierwszego pobrania Large v3 z Hugging Face.
- Logi `OSLog` zawierają stany, czasy i liczbę próbek, nigdy audio ani tekst.
- `OSSignposter` mierzy start mikrofonu, sygnał gotowości, transkrypcję,
  wklejanie i utracone bufory bez przechowywania treści.
- Przed pobraniem modelu sprawdzane jest wolne miejsce, a niekompletny katalog
  trafia do kwarantanny.

## Dystrybucja

Domyślny skrypt tworzy arm64 bundle z Hardened Runtime i stabilnym podpisem
ad-hoc dla prywatnej instalacji. Tryb `ELISE_PRODUCTION=1` odrzuca podpis lokalny
i wymaga tożsamości `Developer ID Application`. `scripts/notarize.sh` wysyła
archiwum przez `notarytool`, stapluje ticket i wykonuje końcową ocenę
Gatekeepera.
