# Problemy, decyzje i rozwiązania

Ten dokument opisuje problemy wykryte podczas budowy Elise Voice oraz powody
wyboru obecnych rozwiązań. Jest rejestrem technicznym, nie listą otwartych
usterek.

## 1. Tożsamość aplikacji i uprawnienia macOS

Pierwsze uruchomienia z terminala zmieniały tożsamość procesu widzianą przez
TCC. Skutkiem były powtarzające się prośby o Dostępność albo brak pozycji Elise
Voice na liście Mikrofon. Aplikacja ma teraz stały bundle ID
`com.elisevoice.app`, stabilny designated requirement dla prywatnego podpisu
ad-hoc i zawsze jest uruchamiana z `/Applications/EliseVoice.app`. Opis użycia
mikrofonu znajduje się w `Info.plist`, a menu zawiera bezpośrednie odnośniki do
obu paneli prywatności.

Publiczna dystrybucja nadal wymaga zewnętrznej tożsamości Developer ID i profilu
notarytool. Skrypty traktują ich brak jako błąd w trybie produkcyjnej
dystrybucji, zamiast po cichu tworzyć paczkę bez notaryzacji.

## 2. Przywracanie okien po awarii

macOS próbował odtwarzać nieistniejące okna aplikacji panelowej i pokazywał
komunikat o nieoczekiwanym zakończeniu. Delegat wyłącza bezpieczne przywracanie
stanu, a aplikacja ustawia `ApplePersistenceIgnoreState`. Recording Window jest
odtwarzany wyłącznie z bieżącego stanu koordynatora.

## 3. Czytelność i charakter Recording Window

Jasna tapeta powodowała utratę cyjanowych konturów, a agresywne przetworzenie
portretu tworzyło zbyt grube linie i nienaturalne oczy. Finalny panel używa
transparentnego portretu `ElisePortraitTransparent-v5.png`, szablonowego
gradientu o wysokim kontraście, subtelnego cienia i niezależnej fali głosu.
Panel jest bezramkowy, nie przejmuje fokusu, pojawia się pod notchem i renderuje
animację tylko wtedy, gdy jest widoczny.

## 4. Zawieszony strumień mikrofonu

Zmiany urządzenia, wybudzenie komputera i przeciążenie callbacku Core Audio
potrafiły pozostawić interfejs w stanie nagrywania bez nowych próbek. Callback
czasu rzeczywistego wykonuje obecnie tylko nieblokującą kopię do puli sześciu
buforów. Konwersja i analiza działają na osobnej kolejce. Heartbeat wykrywa brak
próbek, a koordynator odbudowuje strumień z wykładniczym opóźnieniem. Zgubione
bufory są liczone i raportowane bez treści audio.

## 5. Fałszywe wybudzenia ogólnego modelu

Pojedynczy wynik klasyfikatora bywał wysoki dla kliknięcia, słowa „Lis” albo
fragmentu zdania. Pierwszy etap wymaga potwierdzenia w czasie: dwóch
kompatybilnych okien lub dwóch mocnych wyników w ograniczonym przedziale. Tania
bramka energii ogranicza liczbę inferencji, a cooldown blokuje serię wywołań.
Pierwszy etap celowo generuje kandydata, nie ostateczną decyzję.

## 6. Brak reakcji na ILIS, ILIZ i ELAJS

Ogólny model i tekstowy weryfikator Large v3 nie odwzorowywały konsekwentnie
krótkich angielskich wariantów wymowy polskiego użytkownika. Dodano jawny proces
kalibracji: 24 pozytywne nagrania i 30 trudnych negatywów. Osobisty model jest
małym `MLSoundClassifier` opartym na Audio Feature Print i działa lokalnie.

Pierwsza implementacja oceniała wiele przesuniętych okien z 2,4-sekundowego
bufora. Ten sam dźwięk mógł więc dostać inną decyzję niż jednosekundowa próbka
ucząca. Finalna implementacja wyszukuje ostatnią wyspę mowy, szacuje próg z
lokalnego tła, dodaje 120 ms początku i klasyfikuje dokładnie jedno okno 1 s.
Test produkcyjnego kodu rozpoznaje poprawnie wszystkie 54/54 bezpośrednie
próbki, również po osadzeniu ich w kontekście bufora na żywo.

Eksperyment z odtwarzaniem próbek przez głośnik został odrzucony. Dodawał drugą
charakterystykę głośnika, akustykę pokoju i ponowną charakterystykę mikrofonu,
choć normalne użycie to jedna droga „użytkownik → mikrofon”. Dane takie obniżały
separację klas i nie są częścią finalnego treningu.

## 7. Niechciany tekst po ciszy

Whisper potrafi wygenerować krótką grzecznościową frazę, na przykład
„Dziękuję”, dla nagrania bez intencjonalnej mowy. VAD śledzi najdłuższy ciąg
mowy dopiero po krótkiej osłonie sygnału startowego. Jeżeli nagranie nie zawiera
wystarczającej mowy, transkrypcja i wklejanie są całkowicie pomijane. Dodatkowa
warstwa `TranscriptFormatter` odrzuca puste i techniczne szczątki wyniku.

## 8. Długie dyktowanie i wykorzystanie M4 Pro

Nagrania przekraczające pojedyncze okno modelu wymagają dzielenia. WhisperKit
pracuje z VAD i składa segmenty. Pomiar 99,5-sekundowego polskiego nagrania
wskazał trzy równoległe workery jako właściwy kompromis dla M4 Pro. Encoder i
decoder wykorzystują CPU oraz Neural Engine, a obliczenia mel również GPU.
Twardy limit nagrania wynosi 5 minut, a watchdog transkrypcji skaluje się z
długością audio.

## 9. Bezpieczne wklejanie

Fokus może zmienić się między początkiem nagrania a zakończeniem transkrypcji.
Elise zapamiętuje proces i dokładny element AX, odrzuca `AXSecureTextField`,
ponownie sprawdza fokus przed wklejeniem i preferuje bezpośrednie ustawienie
wartości AX. Kontrolowane `⌘V` jest ścieżką zapasową z przywróceniem poprzedniej
zawartości schowka. Przy błędzie tekst pozostaje w schowku zamiast trafić do
przypadkowego pola.

## 10. Prywatność a stałe nasłuchiwanie

Wybudzenie głosowe wymaga aktywnego urządzenia wejściowego; nie da się reagować
na hasło przy fizycznie wyłączonym mikrofonie. W trybie gotowości audio jest
przechowywane wyłącznie w nadpisywanym trzysekundowym buforze RAM. Nie ma zapisu
rozmów, historii ani automatycznego uczenia. Wyłączenie pozycji „Wybudzanie
głosem ELISE” w menu całkowicie zatrzymuje mikrofon do czasu użycia `⌥Space`.

## Stan końcowy

Kod kompiluje się w Swift 6 z ostrzeżeniami traktowanymi jako błędy. Usunięto
nieużywane przypadki błędów i wycofane ścieżki eksperymentalne. Finalny pakiet
arm64 przechodzi testy modelu hasła, osobistego weryfikatora, dokładnego
weryfikatora tekstowego, 99,5-sekundowego dyktowania, podpisu i integralności
bundle’a. Szczegóły uruchomienia tych kontroli są w `KNOW_HOW.md`.
