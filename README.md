# Elise Voice

Wersja 1.6.0 — lokalne dyktowanie po polsku na macOS.

## Działanie

- Po uruchomieniu aplikacji mikrofon pozostaje wyłączony.
- Pierwsze `⌥Space` rozpoczyna nagrywanie i uzbraja głosowe wybudzanie na
  30-minutową sesję pracy.
- W aktywnej sesji wypowiedzenie „ELISE” — jako „ILIS”, „ILIZ” lub „ELAJS” —
  również rozpoczyna nagrywanie.
- Aktywność klawiatury, myszy albo użycie Elise utrzymuje sesję. Po 30 minutach
  rzeczywistej bezczynności mikrofon wyłącza się; kolejne `⌥Space` rozpoczyna
  nową sesję.
- Krótki dwutonowy sygnał potwierdza gotowość — mów od razu po jego zakończeniu.
- Ponowne `⌥Space` kończy nagrywanie natychmiast.
- 20 sekund ciągłej ciszy kończy nagrywanie automatycznie.
- Jeśli po wywołaniu nie padnie żaden tekst, aplikacja niczego nie transkrybuje
  ani nie wkleja.
- Rozpoznany tekst jest wklejany do aktywnego pola tekstowego.
- Recording Window rozwija się spod fizycznego notcha, pokazuje liniową sylwetkę
  Elise i modulację głosu, nie zabierając fokusu z aktualnej aplikacji.
- Aplikacja jest obecna w Docku i rejestruje się jako element uruchamiany przy
  logowaniu.
- W menu aplikacji można całkowicie wyłączyć „Wybudzanie głosem ELISE”. Wtedy
  `⌥Space` nadal dyktuje, ale po zakończeniu mikrofon natychmiast się wyłącza.

Elise Voice nie ma konta, chmury, historii nagrań ani edytora. Język
transkrypcji jest zawsze ustawiony na polski.

Dokumentacja techniczna:

- [ARCHITECTURE.md](ARCHITECTURE.md) — komponenty, przepływy i granice systemu,
- [PROBLEMS.md](PROBLEMS.md) — napotkane problemy i podjęte decyzje,
- [KNOW_HOW.md](KNOW_HOW.md) — budowanie, testowanie, kalibracja i wydanie.

## Modele i wydajność

Końcową transkrypcję wykonuje 4-bitowo skompresowany `Whisper Large v3`:
`argmaxinc/whisperkit-coreml/openai_whisper-large-v3-v20240930_626MB`.

Hasło aktywujące wykrywa dedykowany, kilkukilobajtowy klasyfikator Core ML
`EliseWakeWord`, wytrenowany dla wymowy ILIS, ILIZ i ELAJS z trudnymi próbkami
negatywnymi. Pierwsza decyzja wymaga dwóch zgodnych okien, więc pojedynczy
głośny pik nie wywoła dyktowania. Rzadki kandydat jest dodatkowo
potwierdzany na 2,4-sekundowym buforze przez drugi model Core ML wytrenowany na
głosie właściciela. Aplikacja odnajduje w tym buforze ostatnią wypowiedź,
wyrównuje ją do identycznego jednosekundowego okna jak podczas kalibracji i
dopiero wtedy ocenia. Jeśli nie rozstrzygnie, zapasowym weryfikatorem jest już
załadowany Large v3. Zwykłe „Lis”, „Elisa” czy przypadkowy hałas nie otwierają Recording Window. Core ML
korzysta z Audio Feature Print i dostępnych jednostek CPU, GPU oraz Apple
Neural Engine. Dłuższe nagrania są dzielone przez VAD na okna i składane w
jeden tekst.

Mikrofon działa jako jeden współdzielony strumień 16 kHz. Nie uruchamia się
automatycznie razem z aplikacją. `⌥Space` uzbraja nasłuch, a aktywność
klawiatury, myszy lub Elise podtrzymuje sesję. W aktywnej sesji strumień musi nasłuchiwać w
stanie gotowości, ale audio nie jest zapisywane. Po bezczynności, blokadzie albo
uśpieniu strumień jest zatrzymywany. W RAM istnieje wyłącznie nadpisywany, trzysekundowy bufor
potrzebny do potwierdzenia hasła. Tania bramka energii z pre-roll uruchamia pełny klasyfikator
tylko wokół mowy. Mikrofon wyłącza się także podczas transkrypcji i krótkiego
odzyskiwania po błędzie; po zmianie urządzenia audio strumień jest bezpiecznie
odbudowywany wyłącznie wtedy, gdy sesja nadal jest aktywna. Nagranie dyktowania
istnieje tylko w RAM i jest zwalniane po transkrypcji.

## Instalacja

Skrypt buduje aplikację, instaluje ją w `/Applications`, przypina do Docka i
uruchamia:

```bash
chmod +x scripts/*.sh
./scripts/install.sh
```

Przy pierwszym uruchomieniu macOS poprosi o:

1. dostęp do mikrofonu (pozycja pojawia się w ustawieniach po pierwszej prośbie),
2. dostęp w **Prywatność i ochrona → Dostępność**, potrzebny do wysłania `⌘V`,
3. ewentualne zatwierdzenie w **Ogólne → Elementy logowania**, jeśli wymaga tego
   konfiguracja systemu.

Po każdym uruchomieniu napis `START` oznacza ładowanie lokalnych modeli. Gdy
zniknie, aplikacja jest gotowa. Przy kolejnych wywołaniach dyktowania wystarczy
poczekać na krótki sygnał dźwiękowy; nagrywanie rozpoczyna się na jego końcu.

## Kontrole

```bash
./scripts/check.sh                 # kompilacja i metadane
./scripts/check-wake-word.sh       # ILIS, ILIZ, ELAJS oraz próbka negatywna
./scripts/check-personal-wake-verifier.sh # wszystkie 54 próbki właściciela
./scripts/check-wake-verifier.sh   # drugi etap: hasła kontra Lis/Elisa
./scripts/check-long-dictation.sh  # polskie nagranie dłuższe niż minuta
./scripts/check-production.sh      # pełna kontrola pakietu wydania
./scripts/benchmark-asr.sh         # porównanie 1–4 workerów WhisperKit
```

Własny klasyfikator hasła można odtworzyć poleceniem
`./scripts/train-wake-word.sh`. `./scripts/capture-personal-wake-word.sh`
zbiera lokalny zestaw ILIS/ILIZ/ELAJS konkretnego użytkownika; kolejne
uruchomienie treningu włącza go automatycznie. Nagrania pozostają w `.build` i
nie są kopiowane do aplikacji. Do personalizacji należy używać próbek mówionych
bezpośrednio do mikrofonu — ponowne odtwarzanie przez głośnik dodaje akustykę
pomieszczenia i nie reprezentuje normalnego użycia. Publiczną paczkę Developer ID buduje się po
ustawieniu `ELISE_SIGN_IDENTITY`, a `scripts/notarize.sh` wymusza produkcyjny
podpis, wysyła pakiet przez profil `ELISE_NOTARY_PROFILE` i stapluje ticket.

Prowadzoną kalibrację uruchamia `./scripts/run-personal-calibration.sh`.
Zapisuje ona 24 hasła i 30 trudnych negatywów (około 1,7 MB). Dane nie są
zbierane z dyktowania ani w tle. Trening tworzy osobny osobisty weryfikator;
próbki można usunąć po zakończeniu testów, jeżeli nie będą potrzebne do
późniejszego odtworzenia modelu.

## Przepływ danych

```text
⌥Space → aktywna sesja 30 min
       ↓
Core ML ELISE lub kolejne ⌥Space
            ↓
      strumień 16 kHz
       ↓
20 s ciszy lub ponowne ⌥Space
       ↓
Whisper Large v3 (pl, Core ML) → schowek → ⌘V
```
