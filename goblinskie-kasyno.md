# Goblin Casino – addon do WoW: Forever

Wysokopoziomowy opis projektu: cel, ograniczenia platformy, architektura, gry, losowość, grafika i plan prac.

## 1. Cel

Addon do **World of Warcraft: Forever**, który pozwala graczom w rajdzie (lub gildii) grać między bossami w kolorowe, interaktywne gry losowe o **złoto z gry**. Addon:

- pokazuje salda uczestników i przyjmuje zakłady,
- prowadzi rozgrywkę widoczną jednocześnie u wszystkich graczy,
- wylicza, kto komu ile płaci, i pomaga to rozliczyć przez okno handlu.

Nie jest to kolejny deathroll. Gry mają być widowiskowe (animowany wyścig, rosnący mnożnik, kręcące się koło) i wyglądać jak kolorowe strony kasyn, tylko w klimacie Azeroth.

## 2. Platforma i ograniczenia

- **Silnik/API:** Forever działa na nowoczesnym kliencie (architektura UI Mainline, w większości API z 12.1.5). Addony z Classic się nie przenoszą, trzeba pisać pod nowe API. Folder: `World of Warcraft\_forever_\Interface\AddOns\`.
- **Numer interfejsu w `.toc`:** sprawdzić w grze (`/dump select(4, GetBuildInfo())`).
- **Restrykcje z Midnight obowiązują też w Forever:**
  - `C_ChatInfo.SendAddonMessage` jest ograniczone w instancjach podczas aktywnych walk (boss, M+). Gry działają **między pullami**, a addon musi wykrywać blokadę i wstrzymywać rundę.
  - Część danych (combat log, czat w instancjach) może być „secret values”. **Do zweryfikowania w pierwszej kolejności:** czy komunikaty `/roll` (`CHAT_MSG_SYSTEM`) da się parsować w rajdzie między bossami.
  - Konta trial nie mogą wysyłać wiadomości addonów.
- **Throttling wiadomości:** serwer ogranicza liczbę wiadomości. Używamy **AceComm-3.0** (dzieli długie wiadomości i korzysta z ChatThrottleLib) + **AceSerializer** / LibSerialize. Limit pojedynczej wiadomości to ~255 bajtów, prefiks do 16 znaków.
- **Gold:** `GetMoney()` zwraca saldo własnej postaci (w miedziakach). Addon **nie może sam przelewać złota**: akceptacja handlu i wysyłka poczty wymagają kliknięcia gracza. Addon może jedynie przygotować handel (np. `InitiateTrade` z kliknięcia przycisku) i śledzić, czy przelew się odbył.

## 3. Zasady (polityka Blizzarda)

- Gry wyłącznie w obrębie **rajdu/grupy/gildii**, żadnego ogłaszania na kanałach publicznych (spam).
- **Zero powiązań z prawdziwymi pieniędzmi.** Blizzard zapowiedział agresywne karanie RMT w Forever.
- Blizzard nie wspiera kasyn/deathrolli (nie odzyska złota, jeśli ktoś nie spłaci długu), więc addon musi jasno pokazywać długi i historię.
- Konfigurowalny **limit stawki** (domyślnie np. 100 g) ustawiany przez gospodarza.

## 4. Architektura

```
GoblinCasino/
├── GoblinCasino.toc
├── Libs/                 # Ace3 (AceComm, AceSerializer, AceDB…), ChatThrottleLib
├── Core/
│   ├── Init.lua          # rejestracja prefiksu, zdarzenia, SavedVariables
│   ├── Comm.lua          # warstwa komunikacji (AceComm), wersjonowanie protokołu
│   ├── Session.lua       # lobby, gospodarz, uczestnicy, stany rundy
│   ├── Bets.lua          # zakłady, totalizator, kursy
│   ├── Rolls.lua         # zbieranie /roll, seed, rzuty zastępcze
│   ├── RNG.lua           # deterministyczny PRNG + hash FNV-1a
│   └── Ledger.lua        # księga długów, rozliczenia, historia
├── Games/
│   ├── Wheel.lua         # Koło Fortuny Ogrów
│   ├── MurlocRace.lua    # Wyścigi Murloków
│   └── Rocket.lua        # Goblińska Rakieta
├── UI/
│   ├── Theme.lua         # kolory, czcionki, wspólne fabryki ramek/przycisków
│   ├── Lobby.lua, BetSlip.lua, RollCeremony.lua, Results.lua
│   └── Anim.lua          # pomocnicze AnimationGroup (pulsowanie, konfetti, liczniki)
└── Media/
    ├── Textures/         # .tga (wymiary potęgi 2)
    ├── Fonts/            # Bungee, Rubik (licencja OFL – można dołączyć)
    └── Sounds/           # .ogg
```

### 4.1 Model sesji

- **Gospodarz** (host), zwykle lider rajdu albo dowolny gracz: otwiera rundę, zbiera zakłady, rozsyła listę zakładów, wykonuje rzuty zastępcze.
- **Stany rundy:** `LOBBY → BETTING → LOCKED → ROLLING → PLAYING → RESULTS → SETTLEMENT`.
- Każdy klient trzyma kopię stanu; gospodarz jest źródłem prawdy dla listy zakładów, ale **nie** dla wyniku (wynik wynika z seeda).

### 4.2 Protokół (szkic)

Prefiks: `GoblinCasino`, kanał `RAID`/`PARTY` (ewentualnie `GUILD`), wiadomości serializowane.

| Wiadomość | Nadawca | Treść |
|---|---|---|
| `HELLO` / `BALANCE` | każdy | wersja addonu, saldo (deklarowane) |
| `ROUND_OPEN` | host | id rundy, gra, limit stawki, czas na zakłady, lista zawodników/opcji |
| `BET` | gracz | id rundy, wybór, typ zakładu, stawka |
| `BETS_LOCKED` | host | id rundy, pełna lista zakładów (zamrożona) + hash listy |
| `ROLL_PHASE` | host | id rundy, zakres rzutu, lista oczekiwanych graczy, deadline |
| `SUB_ROLL` | host | gracz, za którego host wykonał rzut zastępczy |
| `SEED` | host | wyliczony seed (suma kontrolna do porównania) |
| `START` | host | start odtwarzania |
| `ACTION` | gracz | akcje w trakcie gry (np. „wyskakuję” w Rakiecie) |
| `RESULT` | host | wynik + lista przelewów (kontrolnie; każdy liczy sam) |
| `PAID` | gracz | potwierdzenie przelewu po handlu |
| `SYNC_REQ` / `SYNC` | każdy / host | odtworzenie stanu po `/reload` |

## 5. Losowość

### 5.1 Seed z rzutów wszystkich uczestników

1. Po `BETS_LOCKED` każdy uczestnik klika **„RZUĆ!”**, czyli `RandomRoll(1, 1000000)` (losowanie po stronie serwera).
2. Każdy klient parsuje **wyłącznie** `CHAT_MSG_SYSTEM` wzorcem zbudowanym z lokalizowanego `RANDOM_ROLL_RESULT` (odporne na podrabianie rzutów w czacie i na różne języki klienta).
3. Zasady:
   - liczy się **pierwszy** rzut gracza po `ROLL_PHASE`, tylko z ustalonym zakresem,
   - imię normalizowane przez `Ambiguate(name, "none")`,
   - gracz, który nie rzuci przed deadline'em, dostaje **rzut zastępczy od hosta** (nigdy nie pomijamy brakującego rzutu: inaczej ostatni gracz mógłby zdecydować o wyniku przez „nierzucenie”); opcjonalnie traci stawkę na rzecz puli.
4. Seed = **FNV-1a (32 bit)** z posortowanych po imieniu par `imię:rzut;`. Wynik niezależny od kolejności komunikatów.
5. Host rozsyła swój seed jako sumę kontrolną; rozbieżność oznacza dociągnięcie brakujących rzutów.

### 5.2 PRNG i symulacja

- `math.random` w WoW nie da się zaseedować, więc używamy **własnego PRNG** (np. LCG Park–Miller lub xorshift32 na `bit.*`).
- Gry „oglądane” (wyścig, koło, arena) są **deterministyczną symulacją** z seeda: cały przebieg liczony z góry, UI tylko odtwarza klatki. Podczas odtwarzania nie ma żadnej komunikacji.
- **Zasada ukrytej informacji:** wszystko, co wynika z seeda, każdy może policzyć zawczasu (kod jest jawny), dlatego seed powstaje dopiero po zamknięciu zakładów. Gry z tajemnicą w trakcie (Rakieta, Skrzynie) losują **na bieżąco** przez kolejne `/roll` hosta.

## 6. Ekonomia: totalizator i rozliczenia

- **Totalizator (pari-mutuel):** wszystkie stawki trafiają do puli; zwycięzcy dzielą pulę proporcjonalnie do stawek. Kurs = pula / suma stawek na dany wybór; zmienia się do zamknięcia zakładów. Brak „kasyna”, które ryzykuje własnym złotem.
- Zakłady dodatkowe (podium, „pierwszy odpadnie”) mają osobne pule.
- **Księga (Ledger):** po rundzie addon wylicza minimalny zestaw przelewów (kto → komu → ile), zapisuje je w SavedVariables i pokazuje statusy: *zapłacone / czeka na handel*.
- **Rozliczenie:** przycisk „Otwórz handel” (płacący) i „Przypomnij” (odbiorca). Addon wykrywa zakończony handel i oznacza dług jako spłacony.
- Saldo gracza jest **deklarowane** przez jego klienta, więc nie jest weryfikowalne. To akceptowalne wśród znajomych; addon nie powinien przyjmować stawki większej niż zgłoszone saldo.

## 7. Gry

### MVP (w kolejności)

1. **Koło Fortuny Ogrów:** koło z polami (kolory, liczby, pola specjalne, np. „Ogr się wkurzył”). Wynik z seeda. Najprostsza gra, służy do przetestowania całego silnika (lobby → zakłady → rzuty → wynik → rozliczenie).
2. **Wyścigi Murloków:** 5 zawodników ze statystykami (szybkość, zryw, niezdarność) i formą zapisywaną między wyścigami. Symulacja z seeda: losowe kroki, sprinty, potknięcia, komentarz. Zakłady: zwycięzca / podium / pierwszy odpadnie. Opcjonalnie „rybka” kładziona na torze przed startem.
3. **Goblińska Rakieta (crash):** mnożnik rośnie; co sekundę host wykonuje `/roll 1-100`, a wynik poniżej rosnącego progu oznacza wybuch. Gracze klikają „Wyskakuję!” (`ACTION`); liczy się kolejność dotarcia do hosta względem jego rzutu.

### Później

- **Skrzynie Mimika:** push-your-luck, każda skrzynia rozstrzygana `/roll`.
- **Kopalnia Koboldów:** wspólne kopanie, wycofanie się w dowolnym momencie, zawalenie przez `/roll`.
- **Arena gnolli:** walka symulowana z seeda, widzowie kupują faworytom przedmioty.
- **Kości Goblina (Liar's Dice)** i **pojedynki 1v1:** ukryta informacja przez commit–reveal (hash tajnego klucza przed rzutem serwera, ujawnienie na końcu).
- **Rajdowy bukmacher:** zakłady na wydarzenia rajdu (kto padnie pierwszy, wipe, czas bossa), rozstrzygane ręcznie przez hosta/głosowanie (addon nie odczyta tych danych z walki).

## 8. Grafika i UI

Makiety (5 ekranów, styl „neonowa goblińska karczma”) są na canvasie: https://claude.ai/artifact/LtvVD8cSZ7yDfH57D8z7AL

Ekrany: **Lobby → Zakłady → Ceremonia rzutów → Wyścig na żywo → Wynik i rozliczenie**. Okno ok. 820×560 px, skalowalne.

### Paleta

| Rola | Kolor |
|---|---|
| Tło (ciemny fiolet) | `#120726` / `#1b0a36` / `#2a0f4a` |
| Złoto (nagłówki, ramki, CTA) | `#ffd84d` / `#ffc93c`, cień `#b7791f` |
| Neonowy róż (akcent, „live”, timer) | `#ff3fa4` |
| Turkus (wyścigi) | `#34e3c4` / `#7ff5e0` |
| Cyjan | `#33e1ff` |
| Zieleń wygranej | `#4dff9a` |
| Pomarańcz (rakieta) | `#ff9a3c` |
| Tekst | `#f7ecff`, pomocniczy `#cdb9ee` |

### Typografia

- **Bungee:** nagłówki, liczby, przyciski (szyld z Vegas).
- **Rubik:** tekst.
- Obie na licencji SIL OFL, więc można je dołączyć do addonu jako `.ttf`.

### Realizacja w WoW

- Brak HTML/CSS: wszystko z **tekstur** (`.tga`, wymiary potęgi 2), `SetColorTexture`, `SetGradient`, tryb mieszania `ADD` dla neonów i poświaty.
- Ramka z żarówkami, tła i przyciski jako tekstury typu 9-slice (rogi + rozciągane krawędzie).
- Animacje: `AnimationGroup` (pulsowanie „NA ŻYWO”, kręcenie koła, konfetti, licznik wygranej), flipbooki dla efektów.
- Zawodnicy: ikony z gry (`INV_Misc_Head_Murloc_*`) lub modele 3D (`ModelScene`/`PlayerModel`). Na makietach są zastępcze kolorowe żetony.
- Dźwięki: brzęk monet, fanfara wygranej (pliki z gry lub własne `.ogg`).

## 9. Plan prac

1. **Spike techniczny (w grze, w rajdzie):** parsowanie `/roll` z `CHAT_MSG_SYSTEM` i `SendAddonMessage` między bossami oraz w trakcie walki (kiedy dokładnie jest blokada).
2. **Rdzeń:** `.toc`, Ace3, Comm, Session, Bets (totalizator), Rolls + RNG, Ledger, SavedVariables.
3. **Koło Fortuny** na prostym UI: pełny przepływ end-to-end z 2–3 graczami.
4. **Theme + tekstury:** wycięcie elementów z makiet, wspólne fabryki ramek i przycisków.
5. **Wyścigi Murloków:** symulacja, odtwarzanie, ekrany z makiet.
6. **Goblińska Rakieta:** akcje na żywo, rzuty hosta co sekundę.
7. Odporność: `/reload` w trakcie rundy (`SYNC`), wyjście gracza z grupy, zmiana hosta, niezgodne wersje addonu.
8. Kolejne gry z listy „Później”.

## 10. Otwarte pytania

- Czy `CHAT_MSG_SYSTEM` z rzutami jest czytelne w instancji (secret values)? Plan B: rzuty przed wejściem lub tylko poza walką.
- Jak dokładnie wygląda blokada wiadomości addonów w instancjach w Forever (tylko encounter czy cała instancja)?
- Kto może być hostem (tylko lider/asystent rajdu czy każdy)?
- Czy gracz, który nie rzucił, traci stawkę, czy tylko dostaje rzut zastępczy?
- Domyślny limit stawki i czy host może go zmieniać.
