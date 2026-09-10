# Zgodność wprowadzania tekstu — audyt 2026-09-10

Nie istnieje jedna metoda gwarantująca automatyczne wpisanie tekstu do każdego
programu na macOS. Celem jest szeroka obsługa standardowych pól i zachowanie
transkrypcji także wtedy, gdy docelowego pola nie można rozpoznać lub aplikacja
nie potwierdza wklejenia.

## Ustalenia i zmiany

| Problem | Zmiana |
| --- | --- |
| Inicjalizacja Accessibility ograniczona do VS Code | Wykrywanie obsługi `AXManualAccessibility` przez odpowiedź aplikacji. Lokalnie protokół udostępniają VS Code i Antigravity. |
| Kontener strony zgłaszany zamiast aktywnego pola | Przeszukiwanie jego potomków z limitem czasu; pierwszeństwo dla rzeczywiście aktywnego pola tekstowego. |
| Samo niepowodzenie wykrycia pola blokowało nagranie | Cel do ręcznego wklejenia: transkrypcja trafia do schowka, a aplikacja wyświetla odpowiednią informację. |
| Bezpośrednia zmiana AX mogła ominąć obsługę wejścia edytora | Standardowe wklejenie przez `⌘V`; test modelu DOM, zdarzenia `input` i cofania. |
| Sukces oceniany na podstawie długości tekstu | Porównanie pełnej oczekiwanej wartości z uwzględnieniem zaznaczenia w UTF-16. |
| Stary schowek wracał po sekundzie niezależnie od odbiorcy | Przywracanie dopiero po dokładnym potwierdzeniu i tylko przy niezmienionym `changeCount`. W innych przypadkach transkrypcja pozostaje dostępna. |
| Zmiana schowka w czasie oczekiwania mogła wkleić obcą treść | Kontrola `changeCount` bezpośrednio przed wysłaniem skrótu. |
| Bufor wyjścia Terminala traktowany jak model wpisywanego tekstu | Terminal i iTerm2 używają wklejania bez porównywania tego bufora do pojedynczej edycji. Tekst pozostaje w schowku. |
| Kilka kursorów potraktowanych jak jedno zaznaczenie | W razie udostępnienia wielu zakresów AX pomijane jest potwierdzanie pojedynczego zastąpienia. |

Zapytanie do aplikacji ma pierwszeństwo przed systemowym. Element otrzymany
z zapytania systemowego musi należeć do właściwego okna; sam inny PID nie
wyklucza poprawnego elementu procesu renderera. Przed wysłaniem skrótu
ponownie sprawdzane są aplikacja, okno, dostępny element i pole hasła.

## Zakres testów

`scripts/check-insertion-integration.sh` uruchamia osobną, tymczasową aplikację
AppKit z osadzonym WebKit. Kompiluje rzeczywisty `TextInserter.swift`, korzysta
z systemowego Accessibility i schowka, a następnie odczytuje model aplikacji
odbierającej tekst. Testy nie korzystają z mikrofonu ani usług sieciowych.
Wymagają sesji graficznej oraz Dostępności dla uruchamiającego terminala.
Podczas ich wykonywania należy pozostawić aktywne okno testowe.

Sprawdzane przypadki:

- `NSTextField`: zastąpienie zaznaczonego emoji, polskie znaki i przywrócenie schowka;
- `NSTextView`: wstawienie do modelu, cofanie i tekst wielowierszowy;
- pole HTML `input` oraz `contenteditable`: wartość w DOM i zdarzenie `input`;
- natywne i webowe pole hasła: odmowa przechwycenia celu;
- zmiana pola: odmowa wklejenia i zachowanie tekstu;
- okno bez rozpoznanego pola: możliwość przechwycenia celu do ręcznego wklejenia;
- zmiana schowka przed wysłaniem skrótu: brak wklejenia obcej treści;
- późniejsze kopiowanie użytkownika: brak nadpisania przez przywracanie schowka;
- aplikacja ignorująca wklejenie: brak pozornego potwierdzenia i ponownej próby;
- odbiorca czytający schowek po 1,4 s: poprawny tekst dokładnie raz.

Dodatkowy test rzeczywistego Terminala przekazuje tekst do tymczasowego
procesu czytającego surowe stdin i porównuje dokładne bajty UTF-8. Nie wysyła
Enter ani nie wykonuje wklejonego tekstu jako polecenia.

Końcowa wersja przeszła cały powyższy zestaw AppKit/WebKit oraz
`scripts/check-production.sh`. Próba Terminala potwierdziła poprawne bajty
przed poprawką rozpoznawania jego bufora wyjścia. Późniejsze próby desktopowe
Terminala i VS Code przerywały kontrole zmiany fokusu; nie zaliczono ich jako
potwierdzenia końcowej wersji. Test zapisanego pliku VS Code z wcześniejszej
poprawki również nie zastępuje ponownego sprawdzenia po tym audycie.

## Granice i dalsze kierunki

| Środowisko | Ograniczenie / kolejna weryfikacja |
| --- | --- |
| Przeglądarki i czaty AI | Testy WebKit nie zastępują testów każdej strony, rozszerzenia i kontrolowanego edytora. Osobno należy sprawdzać konkretne pola Chrome, Copilot i innych rozszerzeń. |
| Electron i jego pochodne | Wykrycie protokołu potwierdza dostępność mechanizmu AX, nie zgodność każdego pola konkretnej aplikacji. |
| Terminale osadzone i niestandardowe | Nie każdy terminal udostępnia informację, która pozwala odróżnić stdin od bufora wyjścia. Nierozpoznany model może dać komunikat o braku potwierdzenia mimo odebrania tekstu. |
| Zdalne pulpity i maszyny wirtualne | Współdzielenie schowka zależy również od klienta, konfiguracji sesji i polityk serwera. Ręczne wklejenie lokalne nie omija wyłączonego przekierowania. |
| Zmienione skróty i układy klawiatury | Obecna automatyczna ścieżka wysyła standardowe `⌘V`. Wymaga osobnej weryfikacji dla zmienionych skrótów i układów. Kandydatem na kolejne ulepszenie jest wywołanie rozpoznanej akcji menu Wklej. |
| Programy blokujące wklejanie | Transkrypcja pozostaje w schowku. Symulacja pisania znak po znaku wymagałaby osobnego trybu i testów; automatyczne przełączenie po niepotwierdzonym wklejeniu mogłoby zdublować tekst. |
| Pole niewidoczne dla AX | Tryb oparty na oknie nie wykrywa zmiany między niewidocznymi polami tego samego okna. Nieznane aplikacje otrzymują ręczne wklejenie. |
| Walidatory i automatyczne formatowanie | Odbiorca może zmienić tekst podczas wklejania. Brak dokładnej zgodności oznacza brak potwierdzenia; nie jest podstawą do automatycznego ponawiania. |

Najbardziej wartościowa następna praca to macierz konkretnych programów
używanych przez użytkownika, szczególnie pól czatów i terminali osadzonych.
Tryb ręczny zapewnia zachowanie wyniku, ale nie oznacza automatycznej
zgodności z każdym środowiskiem.

## Źródła techniczne

- [Electron: włączanie Accessibility przez aplikację zewnętrzną](https://www.electronjs.org/docs/latest/tutorial/accessibility) — protokół `AXManualAccessibility`.
- [Apple: AXUIElementSetAttributeValue](https://developer.apple.com/documentation/applicationservices/1460434-axuielementsetattributevalue) — ustawienie atrybutu i możliwe błędy wsparcia/komunikacji.
- [Apple: NSPasteboard.changeCount](https://developer.apple.com/documentation/appkit/nspasteboard/changecount) — licznik zmian własności schowka, nie potwierdzenie jego odczytania.
- [Microsoft: porównanie funkcji Windows App](https://learn.microsoft.com/en-us/windows-app/compare-platforms-features) — zależności przekierowania schowka od ustawień klienta i sesji.
