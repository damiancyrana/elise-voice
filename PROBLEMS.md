# Problemy, decyzje i rozwiązania

Ten dokument opisuje problemy wykryte podczas budowy Elise Voice oraz powody
obecnych decyzji. Jest rejestrem technicznym, nie listą otwartych usterek.

## 1. Tożsamość aplikacji i uprawnienia macOS

Pierwsze uruchomienia z terminala zmieniały tożsamość procesu widzianą przez
TCC. Skutkiem były powtarzające się prośby o Dostępność albo brak Elise Voice
na liście Mikrofon. Aplikacja ma stały bundle ID `com.elisevoice.app`, stabilny
designated requirement dla prywatnego podpisu ad-hoc i jest uruchamiana z
`/Applications/EliseVoice.app`. Menu zawiera odnośniki do obu paneli
prywatności.

Publiczna dystrybucja wymaga zewnętrznej tożsamości Developer ID i profilu
notarytool. Skrypty traktują ich brak jako błąd w trybie produkcyjnym.

## 2. Przywracanie okien po awarii

macOS próbował odtwarzać nieistniejące okna aplikacji panelowej i pokazywał
komunikat o nieoczekiwanym zakończeniu. Delegat wyłącza bezpieczne przywracanie
stanu, a Recording Window jest odtwarzany wyłącznie z bieżącego stanu
koordynatora.

## 3. Czytelność Recording Window

Jasna tapeta powodowała utratę cyjanowych konturów, a agresywne przetworzenie
portretu tworzyło zbyt grube linie. Finalny panel używa transparentnego portretu
`ElisePortraitTransparent-v5.png`, gradientu o wysokim kontraście, subtelnego
cienia i niezależnej fali głosu. Panel jest bezramkowy, nie przejmuje fokusu i
renderuje animację tylko wtedy, gdy jest widoczny.

## 4. Zawieszony strumień mikrofonu

Zmiany urządzenia, wybudzenie komputera i przeciążenie callbacku Core Audio
potrafiły pozostawić interfejs w stanie nagrywania bez nowych próbek. Callback
czasu rzeczywistego wykonuje tylko nieblokującą kopię do puli sześciu buforów.
Konwersja i zapis działają na osobnej kolejce. Heartbeat wykrywa brak próbek, a
koordynator odbudowuje strumień z wykładniczym opóźnieniem — wyłącznie jeśli
dyktowanie nadal trwa. Zgubione bufory są raportowane bez treści audio.

## 5. Fałszywe wybudzenia ogólnego modelu

Ogólny klasyfikator Audio Feature Print miał odróżniać warianty ILIS, ILIZ i
ELAJS od tła. W praktyce pojedyncze kliknięcie, słowo „Lis”, fragment zwykłego
zdania albo dźwięk z głośników potrafiły otrzymać bardzo wysoki wynik klasy
`elise`. Dodano bramkę energii, porównanie z klasą `background`, dwa zgodne
okna, cooldown i drugi etap weryfikacji.

Te zabezpieczenia zmniejszały liczbę kandydatów w testach, ale nie naprawiały
błędu klasyfikacji na żywo. Model nadal potrafił nadać zwykłej mowie wynik
`ELISE = 1.000`. Potwierdzenie kilku okien nie pomaga, jeżeli każde kolejne okno
jest błędnie oceniane z podobną pewnością.

## 6. Personalny model głosu

Ogólny model i tekstowy weryfikator Large v3 nie odwzorowywały konsekwentnie
krótkich wariantów wymowy polskiego użytkownika. Powstał więc jawny proces
kalibracji: pozytywne nagrania hasła i trudne negatywy. Osobisty
`MLSoundClassifier` również opierał się na Audio Feature Print.

Pierwsza implementacja oceniała wiele przesuniętych okien. Późniejsza
wyszukiwała ostatnią wyspę mowy i klasyfikowała jedno okno takie jak podczas
treningu. Test zapisanych próbek rozpoznawał 54/54 elementy, także w
symulowanym buforze, ale nie przełożyło się to na nieznaną mowę na żywo.
Osobisty weryfikator zwracał `0.999–1.000` również dla głosu, który nie
wypowiadał hasła. Oznaczało to przeuczenie i zbyt słabe pokrycie rozkładu
negatywów, którego test na tym samym małym zbiorze nie ujawniał.

Eksperyment z odtwarzaniem próbek przez głośnik również nie dawał wiarygodnej
walidacji: dodawał charakterystykę głośnika, akustykę pokoju i ponowną
charakterystykę mikrofonu.

## 7. Niechciany tekst po ciszy

Whisper potrafi wygenerować krótką frazę dla nagrania bez intencjonalnej mowy.
VAD śledzi najdłuższy ciąg mowy po osłonie sygnału startowego. Jeżeli nagranie
nie zawiera wystarczającej mowy, transkrypcja i wklejanie są pomijane.
`TranscriptFormatter` odrzuca puste i techniczne szczątki wyniku.

## 8. Długie dyktowanie i wykorzystanie M4 Pro

Nagrania przekraczające okno modelu są dzielone przez VAD. Pomiar
99,5-sekundowego polskiego nagrania wskazał trzy równoległe workery jako
właściwy kompromis dla M4 Pro. Twardy limit nagrania wynosi 5 minut, a watchdog
transkrypcji skaluje się z długością audio.

## 9. Bezpieczne wklejanie

Fokus może zmienić się między początkiem nagrania a zakończeniem transkrypcji.
Elise zapamiętuje aktywną aplikację i element AX, odrzuca
`AXSecureTextField`, ponownie sprawdza fokus i preferuje bezpośrednią zmianę
wartości AX. Element edytora webowego może należeć do procesu renderera, więc
nie jest błędnie odrzucany tylko z powodu innego PID. Brak rzeczywistej zmiany
uruchamia kontrolowane `⌘V`. Przy błędzie tekst pozostaje w schowku zamiast
trafić do przypadkowego pola. Jeżeli Chrome lub inna obsługiwana przeglądarka
nie udostępnia elementu edytora przez AX, Elise weryfikuje zamiast niego aktywną
aplikację i dokładne okno przeglądarki.

## 10. Prywatność i cykl mikrofonu

Aktywacja głosowa z definicji wymaga działającego wejścia audio w okresie
oczekiwania. Nawet bez zapisu na dysk oznacza to analizowanie otoczenia i
utrzymywanie bufora RAM. Po usunięciu tej funkcji nie ma uzasadnienia dla
nasłuchu w stanie gotowości.

Obecnie koordynator uruchamia mikrofon dopiero po `⌥Space` i zatrzymuje go przed
transkrypcją. Blokada, uśpienie i błąd również kończą strumień. Nie ma sesji
30-minutowej, aktywności HID podtrzymującej nasłuch ani ustawienia aktywacji
głosowej w menu.

## 11. Samoczynne wybudzenia od głosu i dźwięku z komputera

Logi z rzeczywistego użycia pokazały jednocześnie:

```text
ELISE keyword detected, confidence: 1.000
Personal acoustic verification confidence: 0.999–1.000
```

Takie wyniki pojawiały się dla zwykłego głosu i głosu z otoczenia, bez
wypowiedzenia hasła. Źródłem problemu nie był skrót ani sama maszyna stanów:
detektory faktycznie zgłaszały fałszywie dodatnią decyzję, po której koordynator
zgodnie z ówczesnym kontraktem rozpoczynał nagrywanie.

Przyczyny techniczne:

- mały, zamknięty zbiór uczący nie reprezentował różnorodności mowy, pogłosów,
  odległości, mikrofonów i dźwięków odtwarzanych przez komputer,
- Audio Feature Print separował próbki kalibracyjne, ale model nie był dobrze
  skalibrowany poza ich rozkładem i zwracał skrajną pewność dla nieznanych
  danych,
- osobisty model używał podobnej reprezentacji i ograniczonych danych, więc nie
  był niezależnym zabezpieczeniem,
- dźwięk z głośników docierający do mikrofonu jest dla klasyfikatora kolejną
  falą audio; bez niezawodnego sygnału referencyjnego nie da się go pewnie
  odróżnić od osoby mówiącej obok komputera,
- awaryjna weryfikacja krótkiego klipu przez Whisper mogła halucynować formę
  podobną do hasła i nie była odpowiednią bramką bezpieczeństwa.

Próba włączenia Voice Processing I/O w celu odejmowania dźwięku głośników
została wycofana. W tym grafie wejściowym powodowała błędy znaczników czasu DSP
i przekazywała ciszę zamiast mowy, przez co przestawało działać zwykłe
dyktowanie.

Dotrenowanie na większym, niezależnym zbiorze mogłoby być osobnym projektem
badawczym, ale nie dawało gwarancji szybkiego usunięcia ryzyka. Fałszywe
wybudzenie może przechwycić i wkleić niezamierzoną wypowiedź, dlatego decyzja
produkcyjna jest bezpiecznie zamknięta: usunięto wybudzanie głosem,
inicjalizację obu detektorów, zasoby modeli w bundle'u, punkty podłączenia do
strumienia audio i menu tej funkcji. Jedynym wyzwalaczem pozostaje `⌥Space`.

## Stan końcowy

Kod kompiluje się w Swift 6 z ostrzeżeniami traktowanymi jako błędy. Finalny
pakiet arm64 przechodzi testy polityk dyktowania, 99,5-sekundowego nagrania,
podpisu i integralności bundle'a. Brama wydania dodatkowo wymaga nieobecności
`EliseWakeWord.mlmodel` oraz `ElisePersonalWakeVerifier.mlmodel` w aplikacji.
Szczegóły kontroli są w `KNOW_HOW.md`.
