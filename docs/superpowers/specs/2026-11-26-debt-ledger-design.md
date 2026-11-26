# Księga długów (Debt Ledger): projekt

Data: 2026-11-26 · Status: do akceptacji

## Po co

Po każdej rundzie przegrani muszą robić trade ze zwycięzcą. Przy kilkunastu rundach wieczorem to dużo
klikania. Gracz chce **grać cały wieczór i rozliczyć się raz na końcu**. Addon ma więc pamiętać,
ile komu wisi, a przy rozliczeniu dawać dowód, że spłata nastąpiła. Ma to zapobiegać sporom typu
„przecież ci oddałem”.

## Cele

- Każdy gracz widzi **tylko swój bilans**: z każdą osobą jedną kwotę netto, czyli „wisisz mu X”
  albo „wisi ci X” (rozliczenie **parami**, bez upraszczania przelewów między osobami trzecimi).
- Bilans rośnie sam z każdej **prawdziwej** rundy (bez practice), w której gracz grał.
- **Dług wisi aż do spłaty**: przez /reload, wylogowanie i kolejne wieczory.
- **Trade jest dowodem.** Addon sam wykrywa udany trade ze złotem i zmniejsza dług.
  Wpis z godziną i kwotą zostaje w księdze.
- Zapas na płatność poza trade’em (np. pocztą): **tylko odbiorca** może odnotować „dostałem”.
- Przy otwarciu trade’u oba addony porównują swoje kwoty i pokazują rozbieżność.

## Nie-cele

- Wspólna księga całej grupy ani widok cudzych długów.
- Minimalizacja liczby przelewów (wariant „B” z rozmowy został odrzucony).
- Synchronizacja całych ksiąg przez sieć (porównujemy tylko kwotę dla pary).
- Wykrywanie poczty, długi przenoszone między postaciami (alty).
- Rundy sprzed tej wersji: księga startuje od zera.

## Anty-cele (porażka, nawet jeśli „działa”)

- Dług znika bez spłaty: przez „Clear history”, limit historii, przycinanie wpisów albo błąd.
- Dług zamyka strona płacąca, bez potwierdzenia odbiorcy (poza wykrytym trade’em).
- Zwykły handel (np. kupno mikstury za 5g) po cichu zjada dług.

## Ograniczenia

- Addon **nie może przelać złota**. Może otworzyć trade z kliknięcia (`InitiateTrade`) i być może
  wpisać kwotę (`SetTradeMoney`, niesprawdzone na Forever, w `pcall`).
- Wykrywanie trade’u na Forever jest **niesprawdzone**. API: `TRADE_SHOW`, `TRADE_MONEY_CHANGED`,
  `TRADE_ACCEPT_UPDATE`, `GetPlayerTradeMoney`, `GetTargetTradeMoney`, `UI_INFO_MESSAGE`
  (`ERR_TRADE_COMPLETE`), `TRADE_CLOSED`, `PLAYER_MONEY`. Pierwszy krok budowy to sprawdzenie
  w grze (patrz „Kolejność”).
- Wiadomości addonów działają tylko w grupie (`Comm`, kanał PARTY/RAID); bywają blokowane w walce.
- Imiona zawsze przez `U.Canonical` (Forever: imię z nazwiskiem, pusty realm).
- Brak Lua na maszynie: testy idą w CI (`tests/run.lua`, fałszywe WoW w `tests/wow.lua`);
  nowe globalne API WoW trzeba dopisać do `.luacheckrc`.
- Cały UI w grze po angielsku.

## Podejścia (rozważone)

- **A) Bilans liczony na bieżąco z historii rund**: mało kodu, ale historia ma limit 200 wpisów
  i przycisk „Clear history”, który wymazałby długi. Odrzucone (anty-cel).
- **B) Osobna księga w SavedVariables** (wybrane): każda runda i każda spłata to wpis, bilans
  to suma wpisów dla danej osoby. Historia rund zostaje niezależna, a lista wpisów jest dowodem przy sporze.
- **C) Wspólna księga uzgadniana przez sieć**: rozwiązuje rozbieżności, ale wymaga ciężkiego
  protokołu. Porównanie samej kwoty przy trade’ie daje prawie to samo. Odrzucone.

## Projekt

### Dane: `ns.db.ledger`

- Księga **na postać**: `ns.db.ledger[me]`, gdzie `me = U.Me()` (SavedVariables są na konto).
- Wpis: `{ t = time(), kind = "round" | "trade" | "received", who = <imię>, amount = <miedziaki> }`
  plus pola zależne od rodzaju: `id`, `game` dla rundy; `gave`, `got` dla trade’u.
- Znak kwoty z perspektywy gracza: **+** = ta osoba jest mi winna więcej, **−** = ja jestem winien
  więcej. Bilans z osobą = suma `amount` jej wpisów.
- **Kwoty w miedziakach.** Stawki są w pełnych złotych (×10000), a trade może zawierać srebro.
- Runda jest zapisywana **raz** (deduplikacja po `round.id`, jak w `Record`; ta sama runda potrafi się
  skończyć dwa razy po /reload).
- **Przycinanie** (decyzja buildera, warunek: bilans nie może się zmienić): stare wpisy osoby można
  zwinąć w jeden wpis `kind = "carry"` z sumą. Nigdy nie usuwać wpisów bez przeniesienia sumy.

### Skąd biorą się wpisy

1. **Runda.** W `Finish` → `Record` (Jackpot.lua), dla rund bez `practice`, w których `me` jest
   w `res.transfers` jako `from` albo `to`: wpis `round` dla drugiej strony każdego przelewu
   (`to == me` → `+amount`, `from == me` → `−amount`). Działa dla wszystkich gier, bo
   wszystkie podają `transfers`.
2. **Trade wykryty automatycznie.** W trakcie trade’u addon śledzi partnera (`UnitName("NPC")`
   → `U.Canonical`) i złoto po obu stronach. Po potwierdzonym zakończeniu tworzy wpis `trade`:
   `amount = (złoto, które dałem − złoto, które dostałem)` w miedziakach. Gdy ja daję, mój dług
   maleje; gdy on daje, jego dług wobec mnie maleje (albo rośnie mój). Wpis powstaje u **obu**
   graczy niezależnie.
   - **Kiedy trade się liczy** (reguła deterministyczna: obie strony widzą ten sam trade, więc
     decydują tak samo bez wymiany wiadomości): trade **tylko ze złotem** (zero przedmiotów po obu
     stronach) z osobą, z którą w księdze jest jakikolwiek wpis (kiedyś graliśmy razem prawdziwą
     rundę). Trade z przedmiotami **nigdy** się nie liczy. To chroni przed anty-celem o miksturze.
     Jeśli przedmioty były zapłatą, odbiorca używa RECEIVED. Złoto dane w drugą stronę (pożyczka)
     też trafia do księgi, bo przekazanie samego złota to w praktyce zawsze spłata albo pożyczka.
     Bez popupów, żeby dwie strony nie odpowiedziały różnie.
   - **Jeśli test w grze nie znajdzie pewnego sygnału końca trade’u:** zapas to zmiana `GetMoney()`
     po `TRADE_CLOSED`, zgodna z kwotami z okna trade’u. Jeśli i to zawiedzie, automat odpada
     i zostaje RECEIVED. Wtedy wracamy do użytkownika.
3. **„Received” ręcznie.** Na osobie, która **mi** wisi, przycisk RECEIVED z polem kwoty
   (domyślnie cały dług). Tworzy wpis `received` z kwotą ujemną. Płacący nie ma takiego
   przycisku, bo dług zamyka tylko odbiorca.
   - **Płacący też się dowiaduje:** addon odbiorcy wysyła w grupie wiadomość „Grom potwierdza
     odbiór 30g od Biki” z unikalnym id. Addon płacącego dopisuje ten sam wpis i odsyła potwierdzenie.
     Bez potwierdzenia addon odbiorcy ponawia wysyłkę, gdy obaj znów są w jednej grupie
     (kolejka w SavedVariables).

**Zasada ogólna:** każdy może sam zmienić swoją księgę **na swoją niekorzyść** (odbiorca: „dostałem”,
umorzenie). Zmiana **na swoją korzyść** wymaga zgody drugiej strony.

Spłata częściowa zmniejsza dług, a nadpłata odwraca jego kierunek. Bez specjalnych przypadków.

### Porównanie kwot przy trade’ie

Gdy otwiera się trade z osobą, z którą jest bilans, addon wysyła w grupie wiadomość (nowy typ w `Comm`)
z imieniem partnera i swoim bilansem z nim. Addon partnera porównuje ją ze swoim bilansem (z odwróconym
znakiem). Jeśli się różnią, obaj widzą komunikat w czacie i na ekranie księgi:
„Grom's addon says you owe 25g, yours says 30g. Check the rounds in your tab.” Lista wpisów na
ekranie księgi pozwala znaleźć brakującą rundę. Poza grupą albo przy blokadzie wiadomości porównanie
się pomija.

**Rozbieżność addon tylko pokazuje, gracze dogadują się sami** (decyzja użytkownika). Addon nie ma
przycisku „przyjmij jego kwotę”. Do ręcznych korekt są dwa narzędzia, oba zgodne z zasadą „na swoją niekorzyść”:

- odbiorca: RECEIVED (jak wyżej);
- **FORGIVE** u odbiorcy: widoczny też wtedy, gdy u odbiorcy bilans to 0, a addon partnera zgłosił w porównaniu,
  że jest mu winien. Bez tego dłużnik z rundą, której wierzyciel nie widział, zostałby
  z długiem nie do zamknięcia. Wysyła wiadomość jak RECEIVED (z id i ponawianiem). U dłużnika zmniejsza dług
  o podaną kwotę, a u wierzyciela zmniejsza jego należność najwyżej do zera.
- dłużnik może w każdej chwili sam dopisać sobie dług (na swoją niekorzyść), np. gdy u niego brakuje rundy.

### UI

- **Przycisk w nagłówku** obok HISTORY, np. „TAB”, z licznikiem/kolorem, gdy coś wisi. Otwiera
  widok `ledger` (nowy `UI/LedgerView.lua`, ten sam układ co HistoryView).
- **Lewa kolumna:** osoby z niezerowym bilansem (na górze „you owe”, potem „owes you”), potem
  rozliczone. Kwota w kolorze: czerwony = wisisz, zielony = wisi ci.
- **Prawa kolumna:** wpisy wybranej osoby (godzina, gra/trade/received, kwota) i przyciski:
  - **TRADE**: `InitiateTrade` z jednostką z `W.UnitFor(name)`. Gdy osoby nie ma w zasięgu albo
    w grupie, komunikat. Po otwarciu okna próba `SetTradeMoney(dług)`, jeśli ja wiszę.
  - **RECEIVED**: tylko gdy ta osoba wisi mnie.
- **Koniec rundy:** obecne „You owe X. Open a trade to pay.” zmienia się na informację o księdze, np.
  „Added to your tab: you owe Grom 30g (total 45g).”
- **Po wykrytym trade’ie** w czacie: „Paid Grom 30g. You're even.” / „Grom paid you 30g. He still owes 15g.”
- **Lobby:** w pasku statystyk krótkie „You owe 45g · owed 30g” (decyzja buildera, czy się mieści).

## Kolejność budowy

1. **Sprawdzenie w grze** (pierwsze, przed resztą): tymczasowe logowanie zdarzeń trade’u do
   `/casino log`. Użytkownik robi jeden trade ze złotem między postaciami i jeden anulowany. Wynik
   rozstrzyga, które zdarzenia potwierdzają zakończenie na Forever i czy `SetTradeMoney` działa.
2. Moduł księgi (`Core/Ledger.lua` albo `Games/Ledger.lua`) z czystą logiką i testami.
3. Podpięcie rund (Record) i komunikatów końca rundy.
4. Wykrywanie trade’u, porównanie kwot.
5. Widok księgi i przycisk w nagłówku.

## Testy

- Logika księgi: wpisy z `transfers` (wygrana, przegrana, Sapper z `loser`), practice pominięte,
  deduplikacja rundy, suma bilansu, spłata częściowa/nadpłata, `received` tylko od odbiorcy,
  przycinanie nie zmienia bilansu.
- Multiplayer (`tests/wow.lua`): po prawdziwej rundzie bilanse dwóch klientów są lustrzane.
- Trade: jeśli `tests/wow.lua` da się łatwo rozszerzyć o zdarzenia trade’u, test „trade 30g → oba
  bilanse spadają o 30g”; inaczej sprawdzenie ręczne w grze.

## Zostawione builderowi

Nazwa przycisku i widoku, dokładne teksty, układ ekranu, przycinanie wpisów, miejsce modułu,
podsumowanie w lobby, szczegóły śledzenia stanu trade’u.
