# Elise Voice

Wersja 1.7.0 — lokalne dyktowanie po polsku na macOS, uruchamiane wyłącznie
skrótem klawiszowym.

## Działanie

- `⌥Space` rozpoczyna nagrywanie.
- Krótki dwutonowy sygnał potwierdza gotowość; należy mówić po jego zakończeniu.
- Ponowne `⌥Space` kończy nagrywanie natychmiast.
- 20 sekund ciągłej ciszy kończy nagrywanie automatycznie.
- Jeśli nie padnie intencjonalna wypowiedź, aplikacja niczego nie transkrybuje
  ani nie wkleja.
- Rozpoznany tekst jest wklejany do pola aktywnego w chwili rozpoczęcia
  dyktowania.
- Recording Window rozwija się spod fizycznego notcha i nie zabiera fokusu z
  aktualnej aplikacji.
- Aplikacja rejestruje się jako element uruchamiany przy logowaniu.

Mikrofon jest wyłączony po uruchomieniu aplikacji, podczas oczekiwania i podczas
transkrypcji. Włącza go tylko `⌥Space`, a po zakończeniu dyktowania strumień jest
zatrzymywany. Dźwięk otoczenia, mowa ani audio odtwarzane przez komputer nie są
zdarzeniami sterującymi.

Tryb aktywacji głosowej został usunięty z wersji produkcyjnej. Modele
`EliseWakeWord` i `ElisePersonalWakeVerifier` nie są ładowane ani pakowane w
aplikacji. Powody tej decyzji i wyniki diagnozy opisuje
[PROBLEMS.md](PROBLEMS.md).

Elise Voice nie ma konta, chmury, historii nagrań ani edytora. Język
transkrypcji jest zawsze ustawiony na polski.

Dokumentacja techniczna:

- [ARCHITECTURE.md](ARCHITECTURE.md) — komponenty, przepływy i granice systemu,
- [PROBLEMS.md](PROBLEMS.md) — napotkane problemy i podjęte decyzje,
- [KNOW_HOW.md](KNOW_HOW.md) — budowanie, testowanie i wydanie.

## Model i wydajność

Jedynym modelem używanym przez aplikację jest 4-bitowo skompresowany Whisper
Large v3:
`argmaxinc/whisperkit-coreml/openai_whisper-large-v3-v20240930_626MB`.
Pracuje lokalnie przez WhisperKit i wykonuje inferencję dopiero po zakończeniu
nagrywania. Dłuższe nagrania są dzielone przez VAD na okna i składane w jeden
tekst.

Nagranie dyktowania istnieje wyłącznie w RAM i jest zwalniane po
transkrypcji. Nie istnieje bufor ciągłego nasłuchu ani automatyczne uczenie na
głosie użytkownika.

## Instalacja

Skrypt buduje aplikację, instaluje ją w `/Applications`, przypina do Docka i
uruchamia:

```bash
chmod +x scripts/*.sh
./scripts/install.sh
```

Przy pierwszym uruchomieniu macOS poprosi o:

1. dostęp do mikrofonu, potrzebny do dyktowania po `⌥Space`,
2. dostęp w **Prywatność i ochrona → Dostępność**, potrzebny do wklejania,
3. ewentualne zatwierdzenie w **Ogólne → Elementy logowania**.

Po uruchomieniu napis `START` oznacza ładowanie lokalnego modelu transkrypcji.
Gdy zniknie, aplikacja jest gotowa.

## Kontrole

```bash
./scripts/check.sh                 # kompilacja, polityki i metadane
./scripts/check-long-dictation.sh  # polskie nagranie dłuższe niż minuta
./scripts/check-production.sh      # pełna kontrola pakietu wydania
./scripts/benchmark-asr.sh         # porównanie 1–4 workerów WhisperKit
```

Brama produkcyjna sprawdza również, że pakiet nie zawiera modeli aktywacji
głosowej. Stare skrypty eksperymentalne do treningu mogą pozostać w repozytorium
jako materiał badawczy, ale nie należą do procesu wydania i nie są wykonywane
przez aplikację.

Publiczną paczkę Developer ID buduje się po ustawieniu
`ELISE_SIGN_IDENTITY`; `scripts/notarize.sh` wymusza produkcyjny podpis, wysyła
pakiet przez profil `ELISE_NOTARY_PROFILE` i stapluje ticket.

## Przepływ danych

```text
⌥Space → mikrofon 16 kHz → nagrywanie
                              ↓
             ⌥Space / 20 s ciszy / limit 5 min
                              ↓
              mikrofon wyłączony → Whisper Large v3 (pl)
                              ↓
                         schowek → ⌘V
```
